{-# LANGUAGE LambdaCase #-}

module Bcc.Wallet.Kernel.Migration
    ( migrateLegacyDataLayer
    , sanityCheckSpendingPassword
    ) where

import           Universum

import           Data.Acid.Advanced (update')
import           Data.Text (pack)
import           Data.Time (defaultTimeLocale, formatTime, getCurrentTime,
                     iso8601DateFormat)
import           Pos.Crypto.Signing (checkPassMatches)
import           System.Directory (doesDirectoryExist, makeAbsolute, renamePath)

import           Formatting ((%))
import qualified Formatting as F

import           Pos.Core.NetworkMagic (makeNetworkMagic)
import           Pos.Crypto (EncryptedSecretKey)
import           Pos.Util.Wlog (Severity (..))

import qualified Bcc.Wallet.Kernel as Kernel
import           Bcc.Wallet.Kernel.DB.AcidState (UpdateHdRootPassword (..))
import qualified Bcc.Wallet.Kernel.DB.HdWallet as HD
import           Bcc.Wallet.Kernel.DB.InDb (InDb (..))
import qualified Bcc.Wallet.Kernel.DB.Read as Kernel
import qualified Bcc.Wallet.Kernel.Internal as Kernel
import           Bcc.Wallet.Kernel.Keystore as Keystore
import qualified Bcc.Wallet.Kernel.Read as Kernel
import           Bcc.Wallet.Kernel.Restore (restoreWallet)
import           Bcc.Wallet.Kernel.Util.Core (getCurrentTimestamp)

{-------------------------------------------------------------------------------
  Pure helper functions for migration.
-------------------------------------------------------------------------------}

--- | Tries to check the existence of the DB at 'FilePath'. It first tries to
-- check for the input 'FilePath' as-it-is. If this fails, it tries to check
-- for absolute path.
-- This is sometimes necessary if the DB path is given with paths like
-- '../wallet-db'. Apparently `doesDirectoryExist` for such a relative path
-- was returning 'False', after making the path absolute.
resolveDbPath :: FilePath -> IO (Maybe FilePath)
resolveDbPath fp = do
    exists <- doesDirectoryExist fp
    case exists of
         True  -> return (Just fp)
         False -> do
             absPath  <- makeAbsolute fp
             absExist <- doesDirectoryExist absPath
             return $ if absExist then Just absPath else Nothing

--- | Move the legacy database into a backup directory.
moveLegacyDB :: FilePath -> IO FilePath
moveLegacyDB filepath = do
    now <- getCurrentTime
    let backupPath =  filepath
                   <> "-backup-"
                   <> formatTime defaultTimeLocale (iso8601DateFormat (Just "%H_%M_%S")) now
    renamePath filepath backupPath
    return backupPath

-- | Migrates all wallets present in the Keystore by restoring each wallet from
-- its encrypted secret key. Since the spending password is not available, we
-- cannot create a default address for new wallets. This has the effect that
-- the user won't be able to rely on transacting with a default address
-- while restoration is in progress.
--
-- When @forced@ is False we are lenient in logging any error and continuing
-- rather than crashing the node. The rationale is that if
-- we leave the node running, we would give the user a chance
-- to submit a bug report from the Bezalel interface.
--
-- However when @forced@ is True the migration is a all-or-nothing.
-- If anything fails the node crashes.
migrateLegacyDataLayer :: Kernel.PassiveWallet
                       -> FilePath
                       -> Bool
                       -> IO ()
migrateLegacyDataLayer pw unresolvedDbPath forced = do
    logMsg Info "Starting wallet(s) migration"

    resolved <- resolveDbPath unresolvedDbPath
    case resolved of
       Nothing -> -- We assume no migration is needed and we move along
            case forced of
                True -> do
                    logMsg Error $ "Migration failed! Legacy DB was not found at " <> pack unresolvedDbPath <> ", but migration is forced"
                    exitFailure
                False -> do
                    logMsg Info $ "No legacy DB at " <> pack unresolvedDbPath <> ", migration is not needed."
       Just legacyDbPath -> do
           wKeys <- Keystore.getKeys (pw ^. Kernel.walletKeystore)
           mapM_ (restore pw forced) wKeys

           -- asynchronous restoration still runs at this point.
           logMsg Info $ "Migration succeeded, restoration of migrated wallets in progress..."

           -- Now we can move the directory
           backupPath <- moveLegacyDB legacyDbPath

           -- asynchronous restoration still runs at this point.
           logMsg Info $ "acid state migration succeeded. Old db backup can be found at " <> pack backupPath
    where
        logMsg = pw ^. Kernel.walletLogMessage

restore :: Kernel.PassiveWallet
        -> Bool
        -> EncryptedSecretKey
        -> IO ()
restore pw forced esk = do
    let logMsg = pw ^. Kernel.walletLogMessage
        nm     = makeNetworkMagic (pw ^. Kernel.walletProtocolMagic)
        rootId = HD.eskToHdRootId nm esk

    let -- DEFAULTS for wallet restoration
        hasSpendingPassword   = isNothing $ checkPassMatches mempty esk
        defaultAddress        = Nothing
        defaultWalletName     = HD.WalletName "<Migrated Wallet>"
        defaultAssuranceLevel = HD.AssuranceLevelStrict

    res <- restoreWallet pw
                         hasSpendingPassword
                         defaultAddress
                         defaultWalletName
                         defaultAssuranceLevel
                         esk

    case res of
         Right (restoredRoot, balance) -> do
             let msg = "Migrating " % F.build
                        % " with balance " % F.build
             logMsg Info (F.sformat msg restoredRoot balance)
         Left err -> do
             let errMsg = "Couldn't migrate " % F.build
                        % " due to : " % F.build % "."
                 msg = F.sformat errMsg rootId err
             case forced of
                False -> logMsg Error msg
                True  -> do
                    logMsg Error ("Migration failed! " <> msg <> " You are advised to delete the newly created db and try again.")
                    exitFailure

-- | Verify that the spending password metadata are correctly set. We mistakenly
-- forgot to port a fix from RCD-47 done on 2.0.x onto 3.0.0 and, for a few
-- users, have migrated / restored their wallet with a wrong spending password
-- metadata (arbitrarily set to `False`), making their wallet completely
-- unusable.
--
-- This checks makes sure that the 'hasSpendingPassword' metadata correctly
-- reflects the wallet condition. To be run on each start-up, unfortunately.
sanityCheckSpendingPassword
    :: Kernel.PassiveWallet
    -> IO ()
sanityCheckSpendingPassword pw = do
    let nm = makeNetworkMagic (pw ^. Kernel.walletProtocolMagic)
    wKeys <- Keystore.getKeys (pw ^. Kernel.walletKeystore)
    db <- Kernel.getWalletSnapshot pw
    lastUpdateNow <- InDb <$> getCurrentTimestamp
    forM_ wKeys $ \esk -> do
        let hasSpendingPassword = case checkPassMatches mempty esk of
                Nothing -> HD.HasSpendingPassword lastUpdateNow
                Just _  -> HD.NoSpendingPassword
        let rootId = HD.eskToHdRootId nm esk
        whenDiscrepancy db rootId hasSpendingPassword restoreTruth >>= \case
            Left (HD.UnknownHdRoot _) ->
                logMsg Error "Failed to update spending password status, HDRoot is gone?"
            Right _ ->
                return ()
  where
    logMsg = pw ^. Kernel.walletLogMessage
    whenDiscrepancy db rootId hasSpendingPassword action = do
        case (hasSpendingPassword, Kernel.lookupHdRootId db rootId) of
            (_, Left e) ->
                return $ Left e
            (HD.HasSpendingPassword _, Right root) | root ^. HD.hdRootHasPassword == HD.NoSpendingPassword ->
                action rootId hasSpendingPassword
            _ -> -- Avoid making a DB update when there's no need
                return $ Right ()
    restoreTruth rootId hasSpendingPassword =
        void <$> update' (pw ^. Kernel.wallets) (UpdateHdRootPassword rootId hasSpendingPassword)
