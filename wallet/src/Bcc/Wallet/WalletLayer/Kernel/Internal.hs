{-# LANGUAGE RankNTypes          #-}

module Bcc.Wallet.WalletLayer.Kernel.Internal (
    nextUpdate
  , applyUpdate
  , postponeUpdate
  , resetWalletState
  , importWallet
  , calculateMnemonic

  , waitForUpdate
  , addUpdate
  ) where

import           Universum

import           Control.Concurrent.MVar (modifyMVar_)
import           Data.Acid.Advanced (update')
import           System.IO.Error (isDoesNotExistError)

import           Pos.Chain.Update (ConfirmedProposalState, SoftwareVersion, HasUpdateConfiguration)
import           Pos.Util.CompileInfo (HasCompileInfo)
import           Pos.Infra.InjectFail (FInject (..), testLogFInject)

import           Bcc.Wallet.API.V1.Types (V1(V1), Wallet, BackupPhrase(BackupPhrase),
                     WalletImport (..), WalletId, Coin, MnemonicBalance(MnemonicBalance))
import           Bcc.Wallet.Kernel.DB.AcidState (AddUpdate (..),
                     ClearDB (..), GetNextUpdate (..), RemoveNextUpdate (..))
import           Bcc.Wallet.Kernel.DB.InDb
import           Bcc.Wallet.Kernel.DB.TxMeta
import qualified Bcc.Wallet.Kernel.Internal as Kernel
import qualified Bcc.Wallet.Kernel.Keystore as Keystore
import qualified Bcc.Wallet.Kernel.NodeStateAdaptor as Node
import qualified Bcc.Wallet.Kernel.Submission as Submission
import           Bcc.Wallet.WalletLayer (CreateWallet (..),
                     ImportWalletError (..))
import           Bcc.Wallet.WalletLayer.Kernel.Wallets (createWallet)
import           Pos.Core.NetworkMagic (makeNetworkMagic, NetworkMagic)
import           Bcc.Wallet.Kernel.Internal (walletProtocolMagic, walletNode)
import           Bcc.Mnemonic (mnemonicToSeed)
import           Pos.Crypto (safeDeterministicKeyGen, EncryptedSecretKey)
import           Pos.Chain.Txp (TxIn, TxOutAux, toaOut, txOutValue, txOutAddress)
import           Bcc.Wallet.Kernel.DB.HdWallet (eskToHdRootId, isOurs)
import qualified Bcc.Wallet.Kernel.DB.HdWallet as HD
import           Bcc.Wallet.WalletLayer.Kernel.Conv (toRootId)
import           Bcc.Wallet.Kernel.Decrypt (WalletDecrCredentials, eskToWalletDecrCredentials)
import           Pos.Core.Common (sumCoins)

-- | Get next update (if any)
--
-- NOTE (legacy): 'nextUpdate", "Pos.Wallet.Web.Methods.Misc"
-- Most of the behaviour of the legacy 'nextUpdate' is now actually implemented
-- directly in the AcidState 'getNextUpdate' update.
nextUpdate :: MonadIO m
           => Kernel.PassiveWallet -> m (Maybe (V1 SoftwareVersion))
nextUpdate w = liftIO $ do
    current <- Node.curSoftwareVersion (w ^. Kernel.walletNode)
    fmap (fmap (V1 . _fromDb)) $
      update' (w ^. Kernel.wallets) $ GetNextUpdate (InDb current)

-- | Apply an update
--
-- NOTE (legacy): 'applyUpdate', "Pos.Wallet.Web.Methods.Misc".
--
-- The legacy implementation does two things:
--
-- 1. Remove the update from the wallet's list of updates
-- 2. Call 'applyLastUpdate' from 'MonadUpdates'
--
-- The latter is implemented in 'applyLastUpdateWebWallet', which literally just
-- a call to 'triggerShutdown'.
--
-- TODO: The other side of the story is 'launchNotifier', where the wallet
-- is /notified/ of updates.
applyUpdate :: MonadIO m => Kernel.PassiveWallet -> m ()
applyUpdate w = liftIO $ do
    update' (w ^. Kernel.wallets) $ RemoveNextUpdate
    Node.withNodeState (w ^. Kernel.walletNode) $ \_lock -> do
      doFail <- liftIO $ testLogFInject (w ^. Kernel.walletFInjects) FInjApplyUpdateNoExit
      unless doFail
        Node.triggerShutdown

-- | Postpone update
--
-- NOTE (legacy): 'postponeUpdate', "Pos.Wallet.Web.Methods.Misc".
postponeUpdate :: MonadIO m => Kernel.PassiveWallet -> m ()
postponeUpdate w = update' (w ^. Kernel.wallets) $ RemoveNextUpdate

-- | Wait for an update notification
waitForUpdate :: MonadIO m => Kernel.PassiveWallet -> m ConfirmedProposalState
waitForUpdate w = liftIO $
    Node.withNodeState (w ^. Kernel.walletNode) $ \_lock ->
        Node.waitForUpdate

-- | Add an update in the DB, this is triggered by the notifier once getting
-- a new proposal from the blockchain
addUpdate :: MonadIO m => Kernel.PassiveWallet -> SoftwareVersion -> m ()
addUpdate w v = liftIO $
    update' (w ^. Kernel.wallets) $ AddUpdate (InDb v)

-- | Reset wallet state
resetWalletState :: MonadIO m => Kernel.PassiveWallet -> m ()
resetWalletState w = liftIO $ do
    -- TODO: reset also the wallet worker (CBR-415)

    -- stop restoration and empty it`s state.
    -- TODO: A restoration may start between this call and the db modification
    -- but as this is for testing only we keep it that way for now. (CBR-415)
    Kernel.stopAllRestorations w

    -- This pauses any effect the Submission worker can have.
    -- We don`t actually stop and restart the thread, but once
    -- we have the MVar the worker can have no effects.
    modifyMVar_ (w ^. Kernel.walletSubmission) $ \_ -> do

        -- clear both dbs.
        update' (w ^. Kernel.wallets) $ ClearDB
        clearMetaDB (w ^. Kernel.walletMeta)
        -- clear submission state.
        return Submission.emptyWalletSubmission

-- | Imports a 'Wallet' from a backup on disk.
importWallet :: MonadIO m
             => Kernel.PassiveWallet
             -> WalletImport
             -> m (Either ImportWalletError Wallet)
importWallet pw WalletImport{..} = liftIO $ do
    secretE <- try $ Keystore.readWalletSecret wiFilePath
    case secretE of
         Left e ->
             if isDoesNotExistError e
                 then return (Left $ ImportWalletFileNotFound wiFilePath)
                 else throwM e
         Right mbEsk -> do
             case mbEsk of
                 Nothing  -> return (Left $ ImportWalletNoWalletFoundInBackup wiFilePath)
                 Just esk -> do
                     res <- liftIO $ createWallet pw (ImportWalletFromESK esk wiSpendingPassword)
                     return $ case res of
                          Left e               -> Left (ImportWalletCreationFailed e)
                          Right importedWallet -> Right importedWallet

-- takes a WalletDecrCredentials and transaction, and returns the Coin output, if its ours
maybeReadcoin :: (HD.HdRootId, WalletDecrCredentials) -> (TxIn, TxOutAux) -> Maybe Coin
maybeReadcoin wkey (_, txout) = case isOurs (txOutAddress . toaOut $ txout) [wkey] of
  (Just _, _)  -> Just $ (txOutValue . toaOut) txout
  (Nothing, _)-> Nothing

calculateMnemonic :: MonadIO m => Kernel.PassiveWallet -> Maybe Bool -> BackupPhrase -> m MnemonicBalance
calculateMnemonic wallet mbool (BackupPhrase mnemonic) = do
  let
    nm :: NetworkMagic
    nm = makeNetworkMagic $ wallet ^. walletProtocolMagic
    esk :: EncryptedSecretKey
    (_pubkey, esk) = safeDeterministicKeyGen (mnemonicToSeed mnemonic) mempty
    hdRoot :: HD.HdRootId
    hdRoot = eskToHdRootId nm esk
    walletid :: WalletId
    walletid = toRootId hdRoot
    wdc = eskToWalletDecrCredentials nm esk
    withNode :: (HasCompileInfo, HasUpdateConfiguration) => Node.Lock (Node.WithNodeState IO) -> Node.WithNodeState IO [Coin]
    withNode _lock = Node.filterUtxo (maybeReadcoin (hdRoot, wdc))
    checkBalance = fromMaybe False mbool
  maybeBalance <- case checkBalance of
    True -> do
      my_coins <- liftIO $ Node.withNodeState (wallet ^. walletNode) withNode
      let
        balance :: Integer
        balance = sumCoins my_coins
      pure $ Just $ balance
    False -> pure Nothing
  pure $ MnemonicBalance walletid maybeBalance
