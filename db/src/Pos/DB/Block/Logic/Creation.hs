{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeOperators       #-}

-- | Functions that retrieve payload from context and create genesis/main blocks
-- with many validations.

module Pos.DB.Block.Logic.Creation
       ( createGenesisBlockAndApply
       , createMainBlockAndApply
       , createMainBlockInternal

       -- * Internals
       , RawPayload (..)
       , createMainBlockPure
       ) where

import           Universum

import           Control.Lens (uses, (-=), (.=), _Wrapped)
import           Control.Monad.Except (MonadError (throwError), runExceptT)
import           Data.Default (Default (def))
import           Formatting (build, fixed, ords, sformat, stext, (%))
import           Serokell.Data.Memory.Units (Byte, memory)

import           Pos.Binary.Class (biSize)
import           Pos.Chain.Block (BlockHeader (..), GenesisBlock,
                     HasSlogGState (..), HeaderHash, MainBlock, MainBody,
                     headerHash, mkGenesisBlock, mkMainBlock)
import qualified Pos.Chain.Block as BC
import           Pos.Chain.Delegation (DelegationVar, DlgPayload (..),
                     ProxySKBlockInfo)
import           Pos.Chain.Genesis as Genesis (Config (..),
                     configBlkSecurityParam, configBlockVersionData,
                     configEpochSlots)
import           Pos.Chain.Ssc (MonadSscMem, SscPayload, defaultSscPayload,
                     stripSscPayload)
import           Pos.Chain.Txp (TxAux (..), TxpConfiguration, emptyTxPayload,
                     mkTxPayload)
import           Pos.Chain.Update (ConsensusEra (..), UpdateConfiguration,
                     UpdatePayload (..), curSoftwareVersion,
                     lastKnownBlockVersion)
import           Pos.Core (BlockCount, EpochIndex, EpochOrSlot (..),
                     SlotId (..), epochIndexL, flattenSlotId, getEpochOrSlot,
                     kChainQualityThreshold, kEpochSlots,
                     localSlotIndexMinBound)
import           Pos.Core.Context (HasPrimaryKey, getOurSecretKey)
import           Pos.Core.Exception (assertionFailed, reportFatalError)
import           Pos.Core.JsonLog (CanJsonLog (..))
import           Pos.Core.JsonLog.LogEvents (MemPoolModifyReason (..))
import           Pos.Core.Reporting (HasMisbehaviorMetrics, reportError)
import           Pos.Core.Slotting (MonadSlots (getCurrentSlot))
import           Pos.Core.Util.LogSafe (logInfoS)
import           Pos.Crypto (SecretKey)
import           Pos.DB.Block.Logic.Internal (MonadBlockApply,
                     applyBlocksUnsafe, normalizeMempool)
import           Pos.DB.Block.Logic.Util (calcChainQualityM)
import           Pos.DB.Block.Logic.VAR (verifyBlocksPrefix)
import           Pos.DB.Block.Lrc (LrcModeFull, lrcSingleShot)
import           Pos.DB.Block.Slog.Logic (ShouldCallBListener (..))
import qualified Pos.DB.BlockIndex as DB
import           Pos.DB.Class (MonadDBRead)
import           Pos.DB.Delegation (clearDlgMemPool, getDlgMempool)
import           Pos.DB.GState.Lock (Priority (..), StateLock, StateLockMetrics,
                     modifyStateLock)
import           Pos.DB.Lrc (HasLrcContext, lrcActionOnEpochReason)
import qualified Pos.DB.Lrc as LrcDB
import           Pos.DB.Ssc (sscGetLocalPayload, sscResetLocal)
import           Pos.DB.Txp (MempoolExt, MonadTxpLocal (..), MonadTxpMem,
                     clearTxpMemPool, txGetPayload, withTxpLocalData)
import           Pos.DB.Update (UpdateContext, clearUSMemPool, getConsensusEra,
                     getMaxBlockSize, usCanCreateBlock, usPreparePayload)
import           Pos.Util (_neHead)
import           Pos.Util.Util (HasLens (..), HasLens')
import           Pos.Util.Wlog (WithLogger, logDebug)

-- | A set of constraints necessary to create a block from mempool.
type MonadCreateBlock ctx m
     = ( HasLens' ctx UpdateConfiguration
       , MonadReader ctx m
       , HasPrimaryKey ctx
       , HasSlogGState ctx -- to check chain quality
       , WithLogger m
       , MonadDBRead m
       , MonadIO m
       , MonadMask m
       , HasLrcContext ctx
       , LrcModeFull ctx m

       -- Mempools
       , HasLens DelegationVar ctx DelegationVar
       , MonadTxpMem (MempoolExt m) ctx m
       , MonadTxpLocal m
       , HasLens UpdateContext ctx UpdateContext
       , MonadSscMem ctx m
       )

----------------------------------------------------------------------------
-- GenesisBlock creation
----------------------------------------------------------------------------

-- | Create genesis block if necessary and apply it.
--
-- We can /try/ to create a genesis block at any moment. However, it
-- only makes sense to do it if the following conditions are met:
--
-- • our tip is a 'MainBlock' and its epoch is less than the given
--   epoch by one;
-- • chain quality is at least 0.5. To be more precise, it means that
--   there are at least `blkSecurityParam` blocks in the last
--   'slotSecurityParam' slots. If this condition is violated, it means
--   that we are either desynchronized\/eclipsed\/attacked or that
--   important security assumption is violated globally.
--   In the former case, it doesn't make sense to create a block.
--   In the latter case, we want the system to stop completely, rather
--   than running in insecure mode.
createGenesisBlockAndApply ::
       forall ctx m.
       ( MonadCreateBlock ctx m
       , CanJsonLog m
       , HasLens StateLock ctx StateLock
       , HasLens (StateLockMetrics MemPoolModifyReason) ctx (StateLockMetrics MemPoolModifyReason)
       , HasMisbehaviorMetrics ctx
       )
    => Genesis.Config
    -> TxpConfiguration
    -> EpochIndex
    -> m (Maybe GenesisBlock)
-- Genesis block for 0-th epoch is hardcoded.
createGenesisBlockAndApply _ _ 0 = pure Nothing
createGenesisBlockAndApply genesisConfig txpConfig epoch = do
    tipHeader <- DB.getTipHeader
    -- preliminary check outside the lock,
    -- must be repeated inside the lock
    needGen   <- needCreateGenesisBlock (configBlkSecurityParam genesisConfig)
                                        epoch
                                        tipHeader
    if needGen
        then modifyStateLock
                 HighPriority
                 ApplyBlock
                 (\_ -> createGenesisBlockDo genesisConfig txpConfig epoch)
        else return Nothing

createGenesisBlockDo
    :: forall ctx m.
       (MonadCreateBlock ctx m, HasMisbehaviorMetrics ctx)
    => Genesis.Config
    -> TxpConfiguration
    -> EpochIndex
    -> m (HeaderHash, Maybe GenesisBlock)
createGenesisBlockDo genesisConfig txpConfig epoch = do
    tipHeader <- DB.getTipHeader
    logDebug $ sformat msgTryingFmt epoch tipHeader
    needCreateGenesisBlock (configBlkSecurityParam genesisConfig) epoch tipHeader
        >>= \case
                False ->
                    (BC.blockHeaderHash tipHeader, Nothing) <$ logShouldNot
                True -> actuallyCreate tipHeader
  where
    -- We need to run LRC here to make 'verifyBlocksPrefix' not hang.
    -- It's important to do it after taking 'StateLock'.
    -- Note that it shouldn't fail, because 'shouldCreate' guarantees that we
    -- have enough blocks for LRC.
    actuallyCreate tipHeader = do
        lrcSingleShot genesisConfig epoch
        leaders <- lrcActionOnEpochReason epoch "createGenesisBlockDo "
            LrcDB.getLeadersForEpoch
        let blk = mkGenesisBlock (configProtocolMagic genesisConfig)
                                 (Right tipHeader)
                                 epoch
                                 leaders
        let newTip = headerHash blk
        curSlot <- getCurrentSlot $ configEpochSlots genesisConfig
        verifyBlocksPrefix genesisConfig curSlot (one (Left blk)) >>= \case
            Left err -> reportFatalError $ pretty err
            Right (undos, pollModifier) -> do
                let undo = undos ^. _Wrapped . _neHead
                applyBlocksUnsafe
                    genesisConfig
                    (ShouldCallBListener True)
                    (one (Left blk, undo))
                    (Just pollModifier)
                normalizeMempool genesisConfig txpConfig
                pure (newTip, Just blk)
    logShouldNot =
        logDebug
            "After we took lock for genesis block creation, we noticed that we shouldn't create it"
    msgTryingFmt =
        "We are trying to create genesis block for " %ords %
        " epoch, our tip header is\n" %build

needCreateGenesisBlock
    :: MonadCreateBlock ctx m
    => BlockCount
    -> EpochIndex
    -> BlockHeader
    -> m Bool
needCreateGenesisBlock k epoch tipHeader = do
    case tipHeader of
        BlockHeaderGenesis _ -> pure False
        -- This is true iff tip is from 'epoch' - 1 and last
        -- 'blkSecurityParam' blocks fully fit into last
        -- 'slotSecurityParam' slots from 'epoch' - 1.
        BlockHeaderMain mb ->
            if mb ^. epochIndexL /= epoch - 1
                then pure False
                else calcChainQualityM k (flattenSlotId (kEpochSlots k) $ SlotId epoch localSlotIndexMinBound) <&> \case
                         Nothing -> False -- if we can't compute chain
                                          -- quality, we probably
                                          -- shouldn't try to create
                                          -- blocks
                         Just cq -> kChainQualityThreshold @Double k <= cq

----------------------------------------------------------------------------
-- MainBlock
----------------------------------------------------------------------------

-- | Create a new main block on top of our tip if possible and apply it.
-- Block can be created if:
-- • our software is not obsolete (see 'usCanCreateBlock');
-- • our tip's slot is less than the slot for which we want to create a block;
-- • there are at least 'blkSecurityParam' blocks in the last
-- 'slotSecurityParam' slots prior to the given slot (i. e. chain quality
-- is decent).
--
-- In theory we can create main block even if chain quality is
-- bad. See documentation of 'createGenesisBlock' which explains why
-- we don't create blocks in such cases.
createMainBlockAndApply ::
       forall ctx m.
       ( MonadCreateBlock ctx m
       , CanJsonLog m
       , HasLens' ctx StateLock
       , HasLens' ctx (StateLockMetrics MemPoolModifyReason)
       )
    => Genesis.Config
    -> TxpConfiguration
    -> SlotId
    -> ProxySKBlockInfo
    -> m (Either Text MainBlock)
createMainBlockAndApply genesisConfig txpConfig sId pske =
    modifyStateLock HighPriority ApplyBlock createAndApply
  where
    createAndApply tip =
        createMainBlockInternal genesisConfig sId pske >>= \case
            Left reason -> pure (tip, Left reason)
            Right blk -> convertRes <$> applyCreatedBlock genesisConfig txpConfig pske blk
    convertRes createdBlk = (headerHash createdBlk, Right createdBlk)

----------------------------------------------------------------------------
-- MainBlock creation
----------------------------------------------------------------------------

-- | Create a new main block for the given slot on top of our
-- tip. This function assumes that lock on block application is taken
-- (hence 'Internal' suffix). It doesn't apply or verify created
-- block. It only checks whether a block can be created (see
-- 'createMainBlockAndApply') and creates it checks passes.
createMainBlockInternal ::
       forall ctx m.
       ( MonadCreateBlock ctx m
       )
    => Genesis.Config
    -> SlotId
    -> ProxySKBlockInfo
    -> m (Either Text MainBlock)
createMainBlockInternal genesisConfig sId pske = do
    tipHeader <- DB.getTipHeader
    logInfoS $ sformat msgFmt tipHeader
    canCreateBlock k sId tipHeader >>= \case
        Left reason -> pure (Left reason)
        Right () -> runExceptT (createMainBlockFinish tipHeader)
  where
    k = configBlkSecurityParam genesisConfig
    msgFmt = "We are trying to create main block, our tip header is\n"%build
    createMainBlockFinish :: BlockHeader -> ExceptT Text m MainBlock
    createMainBlockFinish prevHeader = do
        rawPay <- lift $ getRawPayload genesisConfig (headerHash prevHeader) sId
        sk <- getOurSecretKey
        -- 100 bytes is substracted to account for different unexpected
        -- overhead.  You can see that in bitcoin blocks are 1-2kB less
        -- than limit. So i guess it's fine in general.
        sizeLimit <- (\x -> bool 0 (x - 100) (x > 100)) <$> lift getMaxBlockSize
        block <- createMainBlockPure genesisConfig sizeLimit prevHeader pske sId sk rawPay
        logInfoS $
            "Created main block of size: " <> sformat memory (biSize block)
        block <$ evaluateNF_ block

canCreateBlock :: MonadCreateBlock ctx m
    => BlockCount
    -> SlotId
    -> BlockHeader
    -> m (Either Text ())
canCreateBlock k sId tipHeader =
    runExceptT $ do
        unlessM (lift usCanCreateBlock) $
            throwError "this software is obsolete and can't create block"
        unless (EpochOrSlot (Right sId) > tipEOS) $
            throwError "slot id is not greater than one from the tip block"
        era <- getConsensusEra
        case era of
            Original -> unless (tipHeader ^. epochIndexL == siEpoch sId) $
                throwError "we don't know genesis block for this epoch"
            SBFT _ -> pass
        let flatSId = flattenSlotId (kEpochSlots k) sId
        -- Small heuristic: let's not check chain quality during the
        -- first quarter of the 0-th epoch, because during this time
        -- weird things can happen (we just launched the system) and
        -- usually we monitor it manually anyway.
        unless (flatSId <= fromIntegral (kEpochSlots k `div` 4)) $ do
            chainQualityMaybe <- calcChainQualityM k flatSId
            chainQuality <-
                maybe
                    (throwError "can't compute chain quality")
                    pure
                    chainQualityMaybe
            unless (chainQuality >= kChainQualityThreshold @Double k) $
                throwError $
                sformat
                    ("chain quality is below threshold: "%fixed 3)
                    chainQuality
  where
    tipEOS :: EpochOrSlot
    tipEOS = getEpochOrSlot tipHeader

createMainBlockPure
    :: forall m ctx.
       (MonadError Text m, MonadReader ctx m, HasLens' ctx UpdateConfiguration)
    => Genesis.Config
    -> Byte                   -- ^ Block size limit (real max.value)
    -> BlockHeader
    -> ProxySKBlockInfo
    -> SlotId
    -> SecretKey
    -> RawPayload
    -> m MainBlock
createMainBlockPure genesisConfig limit prevHeader pske sId sk rawPayload = do
    uc <- view (lensOf @UpdateConfiguration)
    bodyLimit <- execStateT (computeBodyLimit uc) limit
    body <- createMainBody k bodyLimit sId rawPayload
    pure (mkMainBlock pm (bv uc) (sv uc) (Right prevHeader) sId sk pske body)
  where
    k = configBlkSecurityParam genesisConfig
    pm = configProtocolMagic genesisConfig
    -- default ssc to put in case we won't fit a normal one
    defSsc :: SscPayload
    defSsc = defaultSscPayload k (siSlot sId)
    computeBodyLimit :: UpdateConfiguration -> StateT Byte m ()
    computeBodyLimit uc = do
        -- account for block header and serialization overhead, etc;
        let musthaveBody = BC.MainBody emptyTxPayload defSsc def def
        let musthaveBlock =
                mkMainBlock pm (bv uc) (sv uc) (Right prevHeader) sId sk pske musthaveBody
        let mhbSize = biSize musthaveBlock
        when (mhbSize > limit) $ throwError $
            "Musthave block size is more than limit: " <> show mhbSize
        identity -= biSize musthaveBlock
    sv = curSoftwareVersion
    bv = lastKnownBlockVersion

----------------------------------------------------------------------------
-- MainBlock apply
----------------------------------------------------------------------------

-- This function tries to apply the block we've just created. It also
-- verifies the block before applying it. If the block turns out to be
-- invalid (which should never happen, but it's a precaution) we clear
-- all mempools and try to create a block again. The returned value is
-- the block we applied (usually it's the same as the argument, but
-- can differ if verification fails).
applyCreatedBlock ::
       forall ctx m.
       (MonadBlockApply ctx m, MonadCreateBlock ctx m)
    => Genesis.Config
    -> TxpConfiguration
    -> ProxySKBlockInfo
    -> MainBlock
    -> m MainBlock
applyCreatedBlock genesisConfig txpConfig pske createdBlock = applyCreatedBlockDo False createdBlock
  where
    epochSlots = configEpochSlots genesisConfig
    slotId = createdBlock ^. BC.mainBlockSlot
    applyCreatedBlockDo :: Bool -> MainBlock -> m MainBlock
    applyCreatedBlockDo isFallback blockToApply = do
        curSlot <- getCurrentSlot epochSlots
        verifyBlocksPrefix genesisConfig curSlot (one (Right blockToApply)) >>= \case
            Left (pretty -> reason)
                | isFallback -> onFailedFallback reason
                | otherwise -> fallback reason
            Right (undos, pollModifier) -> do
                let undo = undos ^. _Wrapped . _neHead
                applyBlocksUnsafe
                    genesisConfig
                    (ShouldCallBListener True)
                    (one (Right blockToApply, undo))
                    (Just pollModifier)
                normalizeMempool genesisConfig txpConfig
                pure blockToApply
    clearMempools :: m ()
    clearMempools = do
        withTxpLocalData clearTxpMemPool
        sscResetLocal epochSlots
        clearUSMemPool
        clearDlgMemPool
    fallback :: Text -> m MainBlock
    fallback reason = do
        let message = sformat ("We've created bad main block: "%stext) reason
        -- REPORT:ERROR Created bad main block
        reportError message
        logDebug $ "Clearing mempools"
        clearMempools
        logDebug $ "Creating empty block"
        createMainBlockInternal genesisConfig slotId pske >>= \case
            Left err ->
                assertionFailed $
                sformat ("Couldn't create a block in fallback: "%stext) err
            Right mainBlock -> applyCreatedBlockDo True mainBlock
    onFailedFallback =
        assertionFailed .
        sformat
            ("We've created bad main block even with empty payload: "%stext)

----------------------------------------------------------------------------
-- MainBody, payload
----------------------------------------------------------------------------

data RawPayload = RawPayload
    { rpTxp    :: ![TxAux]
    , rpSsc    :: !SscPayload
    , rpDlg    :: !DlgPayload
    , rpUpdate :: !UpdatePayload
    }

getRawPayload :: MonadCreateBlock ctx m
    => Genesis.Config
    -> HeaderHash
    -> SlotId
    -> m RawPayload
getRawPayload genesisConfig tip slotId = do
    localTxs <- txGetPayload tip -- result is topsorted
    sscData <- sscGetLocalPayload (configBlkSecurityParam genesisConfig) slotId
    usPayload <- usPreparePayload (configBlockVersionData genesisConfig) tip slotId
    dlgPayload <- getDlgMempool
    let rawPayload =
            RawPayload
            { rpTxp = localTxs
            , rpSsc = sscData
            , rpDlg = dlgPayload
            , rpUpdate = usPayload
            }
    return rawPayload

-- Main purpose of this function is to create main block's body taking
-- limit into account. Usually this function doesn't fail, but we
-- perform some sanity checks just in case.
--
-- Given limit applies only to body, not to other data from block.
createMainBody
    :: forall m .
       MonadError Text m
    => BlockCount
    -> Byte  -- ^ Body limit
    -> SlotId
    -> RawPayload
    -> m MainBody
createMainBody k bodyLimit sId payload =
    flip evalStateT bodyLimit $ do
        let defSsc :: SscPayload
            defSsc = defaultSscPayload k (siSlot sId)
        -- include ssc data limited with max half of block space if it's possible
        sscPayload <- ifM (uses identity (<= biSize defSsc)) (pure defSsc) $ do
            halfLeft <- uses identity (`div` 2)
            -- halfLeft > 0, otherwize stripSscPayload may fail
            let sscPayload = stripSscPayload halfLeft sscData
            flip (maybe $ pure defSsc) sscPayload $ \sscP -> do
                -- we subtract size of empty map because it's
                -- already included in musthaveBlock
                identity -= (biSize sscP - biSize defSsc)
                pure sscP

        -- include delegation certificates and US payload
        let prioritizeUS = even (flattenSlotId (kEpochSlots k) sId)
        let psks = getDlgPayload dlgPay
        (psks', usPayload') <-
            if prioritizeUS then do
                usPayload' <- includeUSPayload
                psks' <- takeSome psks
                return (psks', usPayload')
            else do
                psks' <- takeSome psks
                usPayload' <- includeUSPayload
                return (psks', usPayload')
        let dlgPay' = UnsafeDlgPayload psks'
        -- include transactions
        txs' <- takeSome txs
        -- return the resulting block
        let txPayload = mkTxPayload txs'
        let body = BC.MainBody txPayload sscPayload dlgPay' usPayload'
        return body
  where
    RawPayload { rpTxp = txs
               , rpSsc = sscData
               , rpDlg = dlgPay
               , rpUpdate = usPayload
               } = payload
    -- take from a list until the limit is exhausted or the list ends
    takeSome lst = do
        let go lim [] = (lim, [])
            go lim (x:xs) =
                let len = biSize x
                in if len > lim
                     then (lim, [])
                     else over _2 (x:) $ go (lim - len) xs
        (lim', pref) <- go <$> use identity <*> pure lst
        identity .= lim'
        return pref
    -- include UpdatePayload if we have space for it (not very precise
    -- because we have already counted empty payload but whatever)
    includeUSPayload = do
        lim <- use identity
        let len = biSize usPayload
        if len <= lim
            then (identity -= len) >> return usPayload
            else return def
