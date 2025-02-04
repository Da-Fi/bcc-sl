{-# LANGUAGE CPP                        #-}
{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE ExplicitNamespaces         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE PolyKinds                  #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE StrictData                 #-}
{-# LANGUAGE TemplateHaskell            #-}
-- The hlint parser fails on the `pattern` function, so we disable the
-- language extension here.
{-# LANGUAGE NoPatternSynonyms          #-}
{-# LANGUAGE NamedFieldPuns             #-}

-- Needed for the `Buildable`, `SubscriptionStatus` and `NodeId` orphans.
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Bcc.Wallet.API.V1.Types (
    V1 (..)
  , unV1
  -- * Swagger & REST-related types
  , PasswordUpdate (..)
  , AccountUpdate (..)
  , NewAccount (..)
  , Update
  , New
  , ForceNtpCheck (..)
  -- * Domain-specific types
  -- * Wallets
  , Wallet (..)
  , AssuranceLevel (..)
  , NewWallet (..)
  , WalletUpdate (..)
  , WalletId (..)
  , exampleWalletId
  , WalletOperation (..)
  , SpendingPassword
  , mkSpendingPassword
  -- * Addresses
  , AddressOwnership (..)
  , AddressValidity (..)
  -- * Accounts
  , Account (..)
  , accountsHaveSameId
  , AccountIndex
  , AccountAddresses (..)
  , AccountBalance (..)
  , getAccIndex
  , mkAccountIndex
  , mkAccountIndexM
  , unsafeMkAccountIndex
  , AccountIndexError(..)
  -- * Addresses
  , WalletAddress (..)
  , NewAddress (..)
  , BatchImportResult(..)
  -- * Payments
  , Payment (..)
  , PaymentSource (..)
  , PaymentDistribution (..)
  , Transaction (..)
  , TransactionType (..)
  , TransactionDirection (..)
  , TransactionStatus(..)
  , EstimatedFees (..)
  -- * Updates
  , WalletSoftwareUpdate (..)
  -- * Importing a wallet from a backup
  , WalletImport (..)
  -- * Settings
  , NodeSettings (..)
  , SlotDuration
  , mkSlotDuration
  , BlockchainHeight
  , mkBlockchainHeight
  , LocalTimeDifference
  , mkLocalTimeDifference
  , EstimatedCompletionTime
  , mkEstimatedCompletionTime
  , SyncThroughput
  , mkSyncThroughput
  , SyncState (..)
  , SyncProgress (..)
  , SyncPercentage
  , mkSyncPercentage
  , NodeInfo (..)
  , TimeInfo(..)
  , SubscriptionStatus(..)
  , Redemption(..)
  , RedemptionMnemonic(..)
  , BackupPhrase(..)
  , ShieldedRedemptionCode(..)
  , WAddressMeta (..)
  -- * Some types for the API
  , CaptureWalletId
  , CaptureAccountId
  -- * Core re-exports
  , Core.Address
  , Core.InputSelectionPolicy(..)
  , Core.Coin
  , Core.Timestamp(..)
  , Core.mkCoin
  -- * Wallet Errors
  , WalletError(..)
  , ErrNotEnoughMoney(..)
  , ErrUtxoNotEnoughFragmented(..)
  , msgUtxoNotEnoughFragmented
  , toServantError
  , toHttpErrorStatus
  , MnemonicBalance(..)
  , module Bcc.Wallet.Types.UtxoStatistics
  ) where

import qualified Prelude
import           Universum

import qualified Bcc.Crypto.Wallet as CC
import           Control.Lens (at, to, (?~))
import           Data.Aeson
import qualified Data.Aeson.Options as Aeson
import           Data.Aeson.TH as A
import           Data.Aeson.Types (Parser, Value (..), typeMismatch)
import           Data.Bifunctor (first)
import qualified Data.ByteArray as ByteArray
import qualified Data.ByteString as BS
import           Data.ByteString.Base58 (bitcoinAlphabet, decodeBase58)
import qualified Data.Char as C
import           Data.Default (Default (def))
import           Data.List ((!!))
import           Data.Maybe (fromJust)
import           Data.Semigroup (Semigroup)
import           Data.Swagger hiding (Example, example)
import           Data.Text (Text, dropEnd, toLower)
import           Formatting (bprint, build, fconst, int, sformat, (%))
import qualified Formatting.Buildable
import           Generics.SOP.TH (deriveGeneric)
import           Serokell.Util (listJson)
import qualified Serokell.Util.Base16 as Base16
import           Servant
import           Test.QuickCheck
import           Test.QuickCheck.Gen (Gen (..))
import qualified Test.QuickCheck.Gen as Gen
import qualified Test.QuickCheck.Modifiers as Gen

import           Pos.Node.API

import           Bcc.Wallet.API.Response.JSend (HasDiagnostic (..),
                     noDiagnosticKey)
import           Bcc.Wallet.API.Types.UnitOfMeasure (MeasuredIn (..),
                     UnitOfMeasure (..))
import           Bcc.Wallet.API.V1.Errors (ToHttpErrorStatus (..),
                     ToServantError (..))
import           Bcc.Wallet.API.V1.Generic (jsendErrorGenericParseJSON,
                     jsendErrorGenericToJSON)
import           Bcc.Wallet.API.V1.Swagger.Example (Example, example)
import           Bcc.Wallet.Types.UtxoStatistics
import           Bcc.Wallet.Util (mkJsonKey, showApiUtcTime)

import           Bcc.Mnemonic (Mnemonic)
import qualified Pos.Chain.Txp as Txp
import qualified Pos.Client.Txp.Util as Core
import qualified Pos.Core as Core
import           Pos.Crypto (PublicKey (..), decodeHash, hashHexF)
import qualified Pos.Crypto.Signing as Core
import           Pos.Infra.Communication.Types.Protocol ()
import           Pos.Infra.Diffusion.Subscription.Status
                     (SubscriptionStatus (..))
import           Pos.Infra.Util.LogSafe (BuildableSafeGen (..), buildSafe,
                     buildSafeList, buildSafeMaybe, deriveSafeBuildable,
                     plainOrSecureF)
import           Test.Pos.Core.Arbitrary ()

-- | Declare generic schema, while documenting properties
--   For instance:
--
--    data MyData = MyData
--      { myDataField1 :: String
--      , myDataField2 :: String
--      } deriving (Generic)
--
--   instance ToSchema MyData where
--     declareNamedSchema =
--       genericSchemaDroppingPrefix "myData" (\(--^) props -> props
--         & ("field1" --^ "Description 1")
--         & ("field2" --^ "Description 2")
--       )
--
--   -- or, if no descriptions are added to the underlying properties
--
--   instance ToSchema MyData where
--     declareNamedSchema =
--       genericSchemaDroppingPrefix "myData" (\_ -> id)
--

optsADTCamelCase :: A.Options
optsADTCamelCase = defaultOptions
    { A.constructorTagModifier = mkJsonKey
    , A.sumEncoding            = A.ObjectWithSingleField
    }


--
-- Versioning
--

mkSpendingPassword :: Text -> Either Text SpendingPassword
mkSpendingPassword = fmap V1 . mkPassPhrase

mkPassPhrase :: Text -> Either Text Core.PassPhrase
mkPassPhrase text =
    case Base16.decode text of
        Left e -> Left e
        Right bs -> do
            let bl = BS.length bs
            -- Currently passphrase may be either 32-byte long or empty (for
            -- unencrypted keys).
            if bl == 0 || bl == Core.passphraseLength
                then Right $ ByteArray.convert bs
                else Left $ sformat
                     ("Expected spending password to be of either length 0 or "%int%", not "%int)
                     Core.passphraseLength bl

instance ToJSON (V1 Core.PassPhrase) where
    toJSON = String . Base16.encode . ByteArray.convert

instance FromJSON (V1 Core.PassPhrase) where
    parseJSON (String pp) = case mkPassPhrase pp of
        Left e    -> fail (toString e)
        Right pp' -> pure (V1 pp')
    parseJSON x           = typeMismatch "parseJSON failed for PassPhrase" x

instance Arbitrary (V1 Core.PassPhrase) where
    arbitrary = fmap V1 arbitrary

instance ToSchema (V1 Core.PassPhrase) where
    declareNamedSchema _ =
        pure $ NamedSchema (Just "V1PassPhrase") $ mempty
            & type_ ?~ SwaggerString
            & format ?~ "hex|base16"

instance ToJSON (V1 Core.Coin) where
    toJSON (V1 c) = toJSON . Core.unsafeGetCoin $ c

instance FromJSON (V1 Core.Coin) where
    parseJSON v = do
        i <- Core.Coin <$> parseJSON v
        either (fail . toString) (const (pure (V1 i)))
            $ Core.checkCoin i

instance Arbitrary (V1 Core.Coin) where
    arbitrary = fmap V1 arbitrary

instance ToSchema (V1 Core.Coin) where
    declareNamedSchema _ =
        pure $ NamedSchema (Just "V1Coin") $ mempty
            & type_ ?~ SwaggerNumber
            & maximum_ .~ Just (fromIntegral Core.maxCoinVal)

instance ToJSON (V1 Core.Address) where
    toJSON (V1 c) = String $ sformat Core.addressF c

instance FromJSON (V1 Core.Address) where
    parseJSON (String a) = case Core.decodeTextAddress a of
        Left e     -> fail $ "Not a valid Bcc Address: " <> toString e
        Right addr -> pure (V1 addr)
    parseJSON x = typeMismatch "parseJSON failed for Address" x

instance Arbitrary (V1 Core.Address) where
    arbitrary = fmap V1 arbitrary

instance ToSchema (V1 Core.Address) where
    declareNamedSchema _ =
        pure $ NamedSchema (Just "Address") $ mempty
            & type_ ?~ SwaggerString
            & format ?~ "base58"

instance FromHttpApiData (V1 Core.Address) where
    parseQueryParam = fmap (fmap V1) Core.decodeTextAddress

instance ToHttpApiData (V1 Core.Address) where
    toQueryParam (V1 a) = sformat build a

deriving instance Hashable (V1 Core.Address)
deriving instance NFData (V1 Core.Address)

-- | Represents according to 'apiTimeFormat' format.
instance ToJSON (V1 Core.Timestamp) where
    toJSON timestamp =
        let utcTime = timestamp ^. _V1 . Core.timestampToUTCTimeL
        in  String $ showApiUtcTime utcTime

instance ToHttpApiData (V1 Core.Timestamp) where
    toQueryParam = view (_V1 . Core.timestampToUTCTimeL . to showApiUtcTime)

instance FromHttpApiData (V1 Core.Timestamp) where
    parseQueryParam t =
        maybe
            (Left ("Couldn't parse timestamp or datetime out of: " <> t))
            (Right . V1)
            (Core.parseTimestamp t)

-- | Parses from both UTC time in 'apiTimeFormat' format and a fractional
-- timestamp format.
instance FromJSON (V1 Core.Timestamp) where
    parseJSON = withText "Timestamp" $ \t ->
        maybe
            (fail ("Couldn't parse timestamp or datetime out of: " <> toString t))
            (pure . V1)
            (Core.parseTimestamp t)

instance Arbitrary (V1 Core.Timestamp) where
    arbitrary = fmap V1 arbitrary

instance ToSchema (V1 Core.Timestamp) where
    declareNamedSchema _ =
        pure $ NamedSchema (Just "Timestamp") $ mempty
            & type_ ?~ SwaggerString
            & description ?~ "Time in ISO 8601 format"

--
-- Domain-specific types, mostly placeholders.
--

-- | A 'SpendingPassword' represent a secret piece of information which can be
-- optionally supplied by the user to encrypt the private keys. As private keys
-- are needed to spend funds and this password secures spending, here the name
-- 'SpendingPassword'.
-- Practically speaking, it's just a type synonym for a PassPhrase, which is a
-- base16-encoded string.
type SpendingPassword = V1 Core.PassPhrase

instance Semigroup (V1 Core.PassPhrase) where
    V1 a <> V1 b = V1 (a <> b)

instance Monoid (V1 Core.PassPhrase) where
    mempty = V1 mempty
    mappend = (<>)

instance BuildableSafeGen SpendingPassword where
    buildSafeGen sl pwd =
        bprint (plainOrSecureF sl build (fconst "<spending password>")) pwd

type WalletName = Text

-- | Wallet's Assurance Level
data AssuranceLevel =
    NormalAssurance
  | StrictAssurance
  deriving (Eq, Ord, Show, Enum, Bounded)

instance Arbitrary AssuranceLevel where
    arbitrary = elements [minBound .. maxBound]

deriveJSON
    Aeson.defaultOptions
        { A.constructorTagModifier = toString . toLower . dropEnd 9 . fromString
        }
    ''AssuranceLevel

instance ToSchema AssuranceLevel where
    declareNamedSchema _ =
        pure $ NamedSchema (Just "AssuranceLevel") $ mempty
            & type_ ?~ SwaggerString
            & enum_ ?~ ["normal", "strict"]

deriveSafeBuildable ''AssuranceLevel
instance BuildableSafeGen AssuranceLevel where
    buildSafeGen _ NormalAssurance = "normal"
    buildSafeGen _ StrictAssurance = "strict"

-- | A Wallet ID.
newtype WalletId = WalletId Text deriving (Show, Eq, Ord, Generic)

exampleWalletId :: WalletId
exampleWalletId = WalletId "J7rQqaLLHBFPrgJXwpktaMB1B1kQBXAyc2uRSfRPzNVGiv6TdxBzkPNBUWysZZZdhFG9gRy3sQFfX5wfpLbi4XTFGFxTg"

deriveJSON Aeson.defaultOptions ''WalletId

instance ToSchema WalletId where
  declareNamedSchema = genericDeclareNamedSchema defaultSchemaOptions

instance ToJSONKey WalletId

instance Arbitrary WalletId where
    arbitrary = elements [exampleWalletId]

deriveSafeBuildable ''WalletId
instance BuildableSafeGen WalletId where
    buildSafeGen sl (WalletId wid) =
        bprint (plainOrSecureF sl build (fconst "<wallet id>")) wid

instance FromHttpApiData WalletId where
    parseQueryParam = Right . WalletId

instance ToHttpApiData WalletId where
    toQueryParam (WalletId wid) = wid

instance Hashable WalletId
instance NFData WalletId

-- | A Wallet Operation
data WalletOperation =
    CreateWallet
  | RestoreWallet
  deriving (Eq, Show, Enum, Bounded)

instance Arbitrary WalletOperation where
    arbitrary = elements [minBound .. maxBound]

-- Drops the @Wallet@ suffix.
deriveJSON Aeson.defaultOptions  { A.constructorTagModifier = reverse . drop 6 . reverse . map C.toLower
                                    } ''WalletOperation

instance ToSchema WalletOperation where
    declareNamedSchema _ =
        pure $ NamedSchema (Just "WalletOperation") $ mempty
            & type_ ?~ SwaggerString
            & enum_ ?~ ["create", "restore"]

deriveSafeBuildable ''WalletOperation
instance BuildableSafeGen WalletOperation where
    buildSafeGen _ CreateWallet  = "create"
    buildSafeGen _ RestoreWallet = "restore"


newtype BackupPhrase = BackupPhrase
    { unBackupPhrase :: Mnemonic 12
    }
    deriving stock (Eq, Show)
    deriving newtype (ToJSON, FromJSON, Arbitrary)

deriveSafeBuildable ''BackupPhrase
instance BuildableSafeGen BackupPhrase where
    buildSafeGen _ _  = "<backup phrase>"

instance ToSchema BackupPhrase where
    declareNamedSchema _ =
        pure
            . NamedSchema (Just "V1BackupPhrase")
            $ toSchema (Proxy @(Mnemonic 12))

-- | A type modelling the request for a new 'Wallet'.
data NewWallet = NewWallet {
      newwalBackupPhrase     :: !BackupPhrase
    , newwalSpendingPassword :: !(Maybe SpendingPassword)
    , newwalAssuranceLevel   :: !AssuranceLevel
    , newwalName             :: !WalletName
    , newwalOperation        :: !WalletOperation
    } deriving (Eq, Show, Generic)

deriveJSON Aeson.defaultOptions  ''NewWallet

instance Arbitrary NewWallet where
  arbitrary = NewWallet <$> arbitrary
                        <*> pure Nothing
                        <*> arbitrary
                        <*> pure "My Wallet"
                        <*> arbitrary

instance ToSchema NewWallet where
  declareNamedSchema =
    genericSchemaDroppingPrefix "newwal" (\(--^) props -> props
      & ("backupPhrase"     --^ "Backup phrase to restore the wallet.")
      & ("spendingPassword" --^ "Optional (but recommended) password to protect the wallet on sensitive operations.")
      & ("assuranceLevel"   --^ "Desired assurance level based on the number of confirmations counter of each transaction.")
      & ("name"             --^ "Wallet's name.")
      & ("operation"        --^ "Create a new wallet or Restore an existing one.")
    )


deriveSafeBuildable ''NewWallet
instance BuildableSafeGen NewWallet where
    buildSafeGen sl NewWallet{..} = bprint ("{"
        %" backupPhrase="%buildSafe sl
        %" spendingPassword="%(buildSafeMaybe mempty sl)
        %" assuranceLevel="%buildSafe sl
        %" name="%buildSafe sl
        %" operation"%buildSafe sl
        %" }")
        newwalBackupPhrase
        newwalSpendingPassword
        newwalAssuranceLevel
        newwalName
        newwalOperation

-- | A type modelling the update of an existing wallet.
data WalletUpdate = WalletUpdate {
      uwalAssuranceLevel :: !AssuranceLevel
    , uwalName           :: !Text
    } deriving (Eq, Show, Generic)

deriveJSON Aeson.defaultOptions  ''WalletUpdate

instance ToSchema WalletUpdate where
  declareNamedSchema =
    genericSchemaDroppingPrefix "uwal" (\(--^) props -> props
      & ("assuranceLevel" --^ "New assurance level.")
      & ("name"           --^ "New wallet's name.")
    )

instance Arbitrary WalletUpdate where
  arbitrary = WalletUpdate <$> arbitrary
                           <*> pure "My Wallet"

deriveSafeBuildable ''WalletUpdate
instance BuildableSafeGen WalletUpdate where
    buildSafeGen sl WalletUpdate{..} = bprint ("{"
        %" assuranceLevel="%buildSafe sl
        %" name="%buildSafe sl
        %" }")
        uwalAssuranceLevel
        uwalName

newtype EstimatedCompletionTime = EstimatedCompletionTime (MeasuredIn 'Milliseconds Word)
  deriving (Show, Eq)

mkEstimatedCompletionTime :: Word -> EstimatedCompletionTime
mkEstimatedCompletionTime = EstimatedCompletionTime . MeasuredIn

instance Ord EstimatedCompletionTime where
    compare (EstimatedCompletionTime (MeasuredIn w1))
            (EstimatedCompletionTime (MeasuredIn w2)) = compare w1 w2

instance Arbitrary EstimatedCompletionTime where
    arbitrary = EstimatedCompletionTime . MeasuredIn <$> arbitrary

deriveSafeBuildable ''EstimatedCompletionTime
instance BuildableSafeGen EstimatedCompletionTime where
    buildSafeGen _ (EstimatedCompletionTime (MeasuredIn w)) = bprint ("{"
        %" quantity="%build
        %" unit=milliseconds"
        %" }")
        w

instance ToJSON EstimatedCompletionTime where
    toJSON (EstimatedCompletionTime (MeasuredIn w)) =
        object [ "quantity" .= toJSON w
               , "unit"     .= String "milliseconds"
               ]

instance FromJSON EstimatedCompletionTime where
    parseJSON = withObject "EstimatedCompletionTime" $ \sl -> mkEstimatedCompletionTime <$> sl .: "quantity"

instance ToSchema EstimatedCompletionTime where
    declareNamedSchema _ =
        pure $ NamedSchema (Just "EstimatedCompletionTime") $ mempty
            & type_ ?~ SwaggerObject
            & required .~ ["quantity", "unit"]
            & properties .~ (mempty
                & at "quantity" ?~ (Inline $ mempty
                    & type_ ?~ SwaggerNumber
                    & minimum_ .~ Just 0
                    )
                & at "unit" ?~ (Inline $ mempty
                    & type_ ?~ SwaggerString
                    & enum_ ?~ ["milliseconds"]
                    )
                )

newtype SyncThroughput
    = SyncThroughput (MeasuredIn 'BlocksPerSecond Core.BlockCount)
  deriving (Show, Eq)

mkSyncThroughput :: Core.BlockCount -> SyncThroughput
mkSyncThroughput = SyncThroughput . MeasuredIn

instance Ord SyncThroughput where
    compare (SyncThroughput (MeasuredIn (Core.BlockCount b1)))
            (SyncThroughput (MeasuredIn (Core.BlockCount b2))) =
        compare b1 b2

instance Arbitrary SyncThroughput where
    arbitrary = SyncThroughput . MeasuredIn <$> arbitrary

deriveSafeBuildable ''SyncThroughput
instance BuildableSafeGen SyncThroughput where
    buildSafeGen _ (SyncThroughput (MeasuredIn (Core.BlockCount blocks))) = bprint ("{"
        %" quantity="%build
        %" unit=blocksPerSecond"
        %" }")
        blocks

instance ToJSON SyncThroughput where
    toJSON (SyncThroughput (MeasuredIn (Core.BlockCount blocks))) =
      object [ "quantity" .= toJSON blocks
             , "unit"     .= String "blocksPerSecond"
             ]

instance FromJSON SyncThroughput where
    parseJSON = withObject "SyncThroughput" $ \sl -> mkSyncThroughput . Core.BlockCount <$> sl .: "quantity"

instance ToSchema SyncThroughput where
    declareNamedSchema _ =
        pure $ NamedSchema (Just "SyncThroughput") $ mempty
            & type_ ?~ SwaggerObject
            & required .~ ["quantity", "unit"]
            & properties .~ (mempty
                & at "quantity" ?~ (Inline $ mempty
                    & type_ ?~ SwaggerNumber
                    )
                & at "unit" ?~ (Inline $ mempty
                    & type_ ?~ SwaggerString
                    & enum_ ?~ ["blocksPerSecond"]
                    )
                )

data SyncProgress = SyncProgress {
    spEstimatedCompletionTime :: !EstimatedCompletionTime
  , spThroughput              :: !SyncThroughput
  , spPercentage              :: !SyncPercentage
  } deriving (Show, Eq, Ord, Generic)

deriveJSON Aeson.defaultOptions ''SyncProgress

instance ToSchema SyncProgress where
    declareNamedSchema =
        genericSchemaDroppingPrefix "sp" (\(--^) props -> props
            & "estimatedCompletionTime"
            --^ "The estimated time the wallet is expected to be fully sync, based on the information available."
            & "throughput"
            --^ "The sync throughput, measured in blocks/s."
            & "percentage"
            --^ "The sync percentage, from 0% to 100%."
        )

deriveSafeBuildable ''SyncProgress
-- Nothing secret to redact for a SyncProgress.
instance BuildableSafeGen SyncProgress where
    buildSafeGen sl SyncProgress {..} = bprint ("{"
        %" estimatedCompletionTime="%buildSafe sl
        %" throughput="%buildSafe sl
        %" percentage="%buildSafe sl
        %" }")
        spEstimatedCompletionTime
        spThroughput
        spPercentage

instance Example SyncProgress where
    example = do
        exPercentage <- example
        pure $ SyncProgress
            { spEstimatedCompletionTime = mkEstimatedCompletionTime 3000
            , spThroughput              = mkSyncThroughput (Core.BlockCount 400)
            , spPercentage              = exPercentage
            }

instance Arbitrary SyncProgress where
  arbitrary = SyncProgress <$> arbitrary
                           <*> arbitrary
                           <*> arbitrary

data SyncState =
      Restoring SyncProgress
    -- ^ Restoring from seed or from backup.
    | Synced
    -- ^ Following the blockchain.
    deriving (Eq, Show, Ord)

instance ToJSON SyncState where
    toJSON ss = object [ "tag"  .= toJSON (renderAsTag ss)
                       , "data" .= renderAsData ss
                       ]
      where
        renderAsTag :: SyncState -> Text
        renderAsTag (Restoring _) = "restoring"
        renderAsTag Synced        = "synced"

        renderAsData :: SyncState -> Value
        renderAsData (Restoring sp) = toJSON sp
        renderAsData Synced         = Null

instance FromJSON SyncState where
    parseJSON = withObject "SyncState" $ \ss -> do
        t <- ss .: "tag"
        case (t :: Text) of
            "synced"    -> pure Synced
            "restoring" -> Restoring <$> ss .: "data"
            _           -> typeMismatch "unrecognised tag" (Object ss)

instance ToSchema SyncState where
    declareNamedSchema _ = do
      syncProgress <- declareSchemaRef @SyncProgress Proxy
      pure $ NamedSchema (Just "SyncState") $ mempty
          & type_ ?~ SwaggerObject
          & required .~ ["tag"]
          & properties .~ (mempty
              & at "tag" ?~ (Inline $ mempty
                  & type_ ?~ SwaggerString
                  & enum_ ?~ ["restoring", "synced"]
                  )
              & at "data" ?~ syncProgress
              )

instance Arbitrary SyncState where
  arbitrary = oneof [ Restoring <$> arbitrary
                    , pure Synced
                    ]

-- | A 'Wallet'.
data Wallet = Wallet {
      walId                         :: !WalletId
    , walName                       :: !WalletName
    , walBalance                    :: !(V1 Core.Coin)
    , walHasSpendingPassword        :: !Bool
    , walSpendingPasswordLastUpdate :: !(V1 Core.Timestamp)
    , walCreatedAt                  :: !(V1 Core.Timestamp)
    , walAssuranceLevel             :: !AssuranceLevel
    , walSyncState                  :: !SyncState
    } deriving (Eq, Ord, Show, Generic)
deriveJSON Aeson.defaultOptions ''Wallet

instance ToSchema Wallet where
    declareNamedSchema =
        genericSchemaDroppingPrefix "wal" (\(--^) props -> props
            & "id"
            --^ "Unique wallet identifier."
            & "name"
            --^ "Wallet's name."
            & "balance"
            --^ "Current balance, in Entropic."
            & "hasSpendingPassword"
            --^ "Whether or not the wallet has a passphrase."
            & "spendingPasswordLastUpdate"
            --^ "The timestamp that the passphrase was last updated."
            & "createdAt"
            --^ "The timestamp that the wallet was created."
            & "assuranceLevel"
            --^ "The assurance level of the wallet."
            & "syncState"
            --^ "The sync state for this wallet."
        )

instance Arbitrary Wallet where
  arbitrary = Wallet <$> arbitrary
                     <*> pure "My wallet"
                     <*> arbitrary
                     <*> arbitrary
                     <*> arbitrary
                     <*> arbitrary
                     <*> arbitrary
                     <*> arbitrary

deriveSafeBuildable ''Wallet
instance BuildableSafeGen Wallet where
  buildSafeGen sl Wallet{..} = bprint ("{"
    %" id="%buildSafe sl
    %" name="%buildSafe sl
    %" balance="%buildSafe sl
    %" }")
    walId
    walName
    walBalance

instance Buildable [Wallet] where
    build = bprint listJson

data MnemonicBalance = MnemonicBalance {
      mbWalletId :: !WalletId
    , mbBalance :: !(Maybe Integer)
    } deriving (Eq, Ord, Show, Generic)
deriveJSON Aeson.defaultOptions ''MnemonicBalance

instance ToSchema MnemonicBalance where
    declareNamedSchema =
        genericSchemaDroppingPrefix "mb" (\(--^) props -> props
            & "walletId"
            --^ "Unique wallet identifier."
            & "balance"
            --^ "Current balance, in Entropic."
        )

instance Arbitrary MnemonicBalance where
  arbitrary = MnemonicBalance <$> arbitrary <*> arbitrary

deriveSafeBuildable ''MnemonicBalance
instance BuildableSafeGen MnemonicBalance where
    buildSafeGen sl MnemonicBalance{mbWalletId,mbBalance} = case mbBalance of
      Just bal -> bprint ("{"
        %" id="%buildSafe sl
        %" balance="%build
        %" }")
        mbWalletId
        bal
      Nothing -> bprint ("{"
        %" id="%buildSafe sl
        %" }")
        mbWalletId

instance Example MnemonicBalance where
    example = do
        MnemonicBalance <$> example <*> (pure $ Just 1000000)

instance ToSchema PublicKey where
    declareNamedSchema _ =
        pure $ NamedSchema (Just "PublicKey") $ mempty
            & type_ ?~ SwaggerString
            & format ?~ "base58"

--------------------------------------------------------------------------------
-- Addresses
--------------------------------------------------------------------------------

-- | Whether an address is valid or not.
newtype AddressValidity = AddressValidity { isValid :: Bool }
  deriving (Eq, Show, Generic)

deriveJSON Aeson.defaultOptions ''AddressValidity

instance ToSchema AddressValidity where
    declareNamedSchema = genericSchemaDroppingPrefix "is" (const identity)

instance Arbitrary AddressValidity where
  arbitrary = AddressValidity <$> arbitrary

deriveSafeBuildable ''AddressValidity
instance BuildableSafeGen AddressValidity where
    buildSafeGen _ AddressValidity{..} =
        bprint ("{ valid="%build%" }") isValid

-- | An address is either recognised as "ours" or not. An address that is not
--   recognised may still be ours e.g. an address generated by another wallet instance
--   will not be considered "ours" until the relevant transaction is confirmed.
--
--   In other words, `AddressAmbiguousOwnership` makes an inconclusive statement about
--   an address, whereas `AddressOwnership` is unambiguous.
data AddressOwnership
    = AddressIsOurs
    | AddressAmbiguousOwnership
    deriving (Show, Eq, Generic, Ord)

instance ToJSON (V1 AddressOwnership) where
    toJSON = genericToJSON optsADTCamelCase . unV1

instance FromJSON (V1 AddressOwnership) where
    parseJSON = fmap V1 . genericParseJSON optsADTCamelCase

instance ToSchema (V1 AddressOwnership) where
    declareNamedSchema _ =
        pure $ NamedSchema (Just "V1AddressOwnership") $ mempty
            & type_ ?~ SwaggerString
            & enum_ ?~ ["isOurs", "ambiguousOwnership"]

instance Arbitrary (V1 AddressOwnership) where
    arbitrary = fmap V1 $ oneof
        [ pure AddressIsOurs
        , pure AddressAmbiguousOwnership
        ]

-- | Address with associated metadata locating it in an account in a wallet.
data WAddressMeta = WAddressMeta
    { _wamWalletId     :: !WalletId
    , _wamAccountIndex :: !Word32
    , _wamAddressIndex :: !Word32
    , _wamAddress      :: !(V1 Core.Address)
    } deriving (Eq, Ord, Show, Generic, Typeable)

instance Hashable WAddressMeta
instance NFData WAddressMeta

instance Buildable WAddressMeta where
    build WAddressMeta{..} =
        bprint (build%"@"%build%"@"%build%" ("%build%")")
        _wamWalletId _wamAccountIndex _wamAddressIndex _wamAddress
--------------------------------------------------------------------------------
-- Accounts
--------------------------------------------------------------------------------

-- | Summary about single address.
data WalletAddress = WalletAddress
    { addrId            :: !(V1 Core.Address)
    , addrUsed          :: !Bool
    , addrChangeAddress :: !Bool
    , addrOwnership     :: !(V1 AddressOwnership)
    } deriving (Show, Eq, Generic, Ord)

deriveJSON Aeson.defaultOptions ''WalletAddress

instance ToSchema WalletAddress where
    declareNamedSchema =
        genericSchemaDroppingPrefix "addr" (\(--^) props -> props
            & ("id"            --^ "Actual address.")
            & ("used"          --^ "True if this address has been used.")
            & ("changeAddress" --^ "True if this address stores change from a previous transaction.")
            & ("ownership"     --^ "'isOurs' if this address is recognised as ours, 'ambiguousOwnership' if the node doesn't have information to make a unambiguous statement.")
        )

instance Arbitrary WalletAddress where
    arbitrary = WalletAddress <$> arbitrary
                              <*> arbitrary
                              <*> arbitrary
                              <*> arbitrary

newtype AccountIndex = AccountIndex { getAccIndex :: Word32 }
    deriving (Show, Eq, Ord, Generic)

newtype AccountIndexError = AccountIndexError Word32
    deriving (Eq, Show)

instance Buildable AccountIndexError where
    build (AccountIndexError i) =
        bprint
            ("Account index should be in range ["%int%".."%int%"], but "%int%" was provided.")
            (getAccIndex minBound)
            (getAccIndex maxBound)
            i

mkAccountIndex :: Word32 -> Either AccountIndexError AccountIndex
mkAccountIndex index
    | index >= getAccIndex minBound = Right $ AccountIndex index
    | otherwise = Left $ AccountIndexError index

mkAccountIndexM :: MonadFail m => Word32 -> m AccountIndex
mkAccountIndexM =
    either (fail . toString . sformat build) pure . mkAccountIndex

unsafeMkAccountIndex :: Word32 -> AccountIndex
unsafeMkAccountIndex =
    either (error . sformat build) identity . mkAccountIndex

instance Bounded AccountIndex where
    -- NOTE: minimum for hardened key. See https://bcccoin.myjetbrains.com/youtrack/issue/CO-309
    minBound = AccountIndex 2147483648
    maxBound = AccountIndex maxBound

instance ToJSON AccountIndex where
    toJSON = toJSON . getAccIndex

instance FromJSON AccountIndex where
    parseJSON =
        mkAccountIndexM <=< parseJSON

instance Arbitrary AccountIndex where
    arbitrary =
        AccountIndex <$> choose (getAccIndex minBound, getAccIndex maxBound)

deriveSafeBuildable ''AccountIndex
-- Nothing secret to redact for a AccountIndex.
instance BuildableSafeGen AccountIndex where
    buildSafeGen _ =
        bprint build . getAccIndex

instance ToParamSchema AccountIndex where
    toParamSchema _ = mempty
        & type_ ?~ SwaggerNumber
        & minimum_ .~ Just (fromIntegral $ getAccIndex minBound)
        & maximum_ .~ Just (fromIntegral $ getAccIndex maxBound)

instance ToSchema AccountIndex where
    declareNamedSchema =
        pure . paramSchemaToNamedSchema defaultSchemaOptions

instance FromHttpApiData AccountIndex where
    parseQueryParam =
        first (sformat build) . mkAccountIndex <=< parseQueryParam

instance ToHttpApiData AccountIndex where
    toQueryParam =
        fromString . show . getAccIndex


-- | A wallet 'Account'.
data Account = Account
    { accIndex     :: !AccountIndex
    , accAddresses :: ![WalletAddress]
    , accAmount    :: !(V1 Core.Coin)
    , accName      :: !Text
    , accWalletId  :: !WalletId
    } deriving (Show, Ord, Eq, Generic)


--
-- IxSet indices
--





-- | Datatype wrapping addresses for per-field endpoint
newtype AccountAddresses = AccountAddresses
    { acaAddresses :: [WalletAddress]
    } deriving (Show, Ord, Eq, Generic)

-- | Datatype wrapping balance for per-field endpoint
newtype AccountBalance = AccountBalance
    { acbAmount    :: V1 Core.Coin
    } deriving (Show, Ord, Eq, Generic)

accountsHaveSameId :: Account -> Account -> Bool
accountsHaveSameId a b =
    accWalletId a == accWalletId b
    &&
    accIndex a == accIndex b

deriveJSON Aeson.defaultOptions ''Account
deriveJSON Aeson.defaultOptions ''AccountAddresses
deriveJSON Aeson.defaultOptions ''AccountBalance

instance ToSchema Account where
    declareNamedSchema =
        genericSchemaDroppingPrefix "acc" (\(--^) props -> props
            & ("index"     --^ "Account's index in the wallet, starting at 0.")
            & ("addresses" --^ "Public addresses pointing to this account.")
            & ("amount"    --^ "Available funds, in Entropic.")
            & ("name"      --^ "Account's name.")
            & ("walletId"  --^ "Id of the wallet this account belongs to.")
          )

instance ToSchema AccountAddresses where
    declareNamedSchema =
        genericSchemaDroppingPrefix "aca" (\(--^) props -> props
            & ("addresses" --^ "Public addresses pointing to this account.")
          )

instance ToSchema AccountBalance where
    declareNamedSchema =
        genericSchemaDroppingPrefix "acb" (\(--^) props -> props
            & ("amount"    --^ "Available funds, in Entropic.")
          )

instance Arbitrary Account where
    arbitrary = Account <$> arbitrary
                        <*> arbitrary
                        <*> arbitrary
                        <*> pure "My account"
                        <*> arbitrary

instance Arbitrary AccountAddresses where
    arbitrary =
        AccountAddresses <$> arbitrary

instance Arbitrary AccountBalance where
    arbitrary =
        AccountBalance <$> arbitrary

deriveSafeBuildable ''Account
instance BuildableSafeGen Account where
    buildSafeGen sl Account{..} = bprint ("{"
        %" index="%buildSafe sl
        %" name="%buildSafe sl
        %" addresses="%buildSafe sl
        %" amount="%buildSafe sl
        %" walletId="%buildSafe sl
        %" }")
        accIndex
        accName
        accAddresses
        accAmount
        accWalletId

instance Buildable AccountAddresses where
    build =
        bprint listJson . acaAddresses

instance Buildable AccountBalance where
    build =
        bprint build . acbAmount

instance Buildable [Account] where
    build =
        bprint listJson

-- | Account Update
data AccountUpdate = AccountUpdate {
    uaccName      :: !Text
  } deriving (Show, Eq, Generic)

deriveJSON Aeson.defaultOptions ''AccountUpdate

instance ToSchema AccountUpdate where
  declareNamedSchema =
    genericSchemaDroppingPrefix "uacc" (\(--^) props -> props
      & ("name" --^ "New account's name.")
    )

instance Arbitrary AccountUpdate where
  arbitrary = AccountUpdate <$> pure "myAccount"

deriveSafeBuildable ''AccountUpdate
instance BuildableSafeGen AccountUpdate where
    buildSafeGen sl AccountUpdate{..} =
        bprint ("{ name="%buildSafe sl%" }") uaccName


-- | New Account
data NewAccount = NewAccount
  { naccSpendingPassword :: !(Maybe SpendingPassword)
  , naccName             :: !Text
  } deriving (Show, Eq, Generic)

deriveJSON Aeson.defaultOptions ''NewAccount

instance Arbitrary NewAccount where
  arbitrary = NewAccount <$> arbitrary
                         <*> arbitrary

instance ToSchema NewAccount where
  declareNamedSchema =
    genericSchemaDroppingPrefix "nacc" (\(--^) props -> props
      & ("spendingPassword" --^ "Wallet's protection password, required if defined.")
      & ("name"             --^ "Account's name.")
    )

deriveSafeBuildable ''NewAccount
instance BuildableSafeGen NewAccount where
    buildSafeGen sl NewAccount{..} = bprint ("{"
        %" spendingPassword="%(buildSafeMaybe mempty sl)
        %" name="%buildSafe sl
        %" }")
        naccSpendingPassword
        naccName

deriveSafeBuildable ''WalletAddress
instance BuildableSafeGen WalletAddress where
    buildSafeGen sl WalletAddress{..} = bprint ("{"
        %" id="%buildSafe sl
        %" used="%build
        %" changeAddress="%build
        %" }")
        addrId
        addrUsed
        addrChangeAddress

instance Buildable [WalletAddress] where
    build = bprint listJson

instance Buildable [V1 Core.Address] where
    build = bprint listJson

data BatchImportResult a = BatchImportResult
    { aimTotalSuccess :: !Natural
    , aimFailures     :: ![a]
    } deriving (Show, Ord, Eq, Generic)

instance Buildable (BatchImportResult a) where
    build res = bprint
        ("BatchImportResult (success:"%int%", failures:"%int%")")
        (aimTotalSuccess res)
        (length $ aimFailures res)

instance ToJSON a => ToJSON (BatchImportResult a) where
    toJSON = genericToJSON Aeson.defaultOptions

instance FromJSON a => FromJSON (BatchImportResult a) where
    parseJSON = genericParseJSON Aeson.defaultOptions

instance (ToJSON a, ToSchema a, Arbitrary a) => ToSchema (BatchImportResult a) where
    declareNamedSchema =
        genericSchemaDroppingPrefix "aim" (\(--^) props -> props
            & ("totalSuccess" --^ "Total number of entities successfully imported")
            & ("failures" --^ "Entities failed to be imported, if any")
        )

instance Arbitrary a => Arbitrary (BatchImportResult a) where
    arbitrary = BatchImportResult
        <$> arbitrary
        <*> scale (`mod` 3) arbitrary -- NOTE Small list

instance Arbitrary a => Example (BatchImportResult a)

instance Semigroup (BatchImportResult a) where
    (BatchImportResult a0 b0) <> (BatchImportResult a1 b1) =
        BatchImportResult (a0 + a1) (b0 <> b1)

instance Monoid (BatchImportResult a) where
    mempty = BatchImportResult 0 mempty


-- | Create a new Address
data NewAddress = NewAddress
  { newaddrSpendingPassword :: !(Maybe SpendingPassword)
  , newaddrAccountIndex     :: !AccountIndex
  , newaddrWalletId         :: !WalletId
  } deriving (Show, Eq, Generic)

deriveJSON Aeson.defaultOptions ''NewAddress

instance ToSchema NewAddress where
  declareNamedSchema =
    genericSchemaDroppingPrefix "newaddr" (\(--^) props -> props
      & ("spendingPassword" --^ "Wallet's protection password, required if defined.")
      & ("accountIndex"     --^ "Target account's index to store this address in.")
      & ("walletId"         --^ "Corresponding wallet identifier.")
    )

instance Arbitrary NewAddress where
  arbitrary = NewAddress <$> arbitrary
                         <*> arbitrary
                         <*> arbitrary

deriveSafeBuildable ''NewAddress
instance BuildableSafeGen NewAddress where
    buildSafeGen sl NewAddress{..} = bprint("{"
        %" spendingPassword="%(buildSafeMaybe mempty sl)
        %" accountIndex="%buildSafe sl
        %" walletId="%buildSafe sl
        %" }")
        newaddrSpendingPassword
        newaddrAccountIndex
        newaddrWalletId

-- | A type incapsulating a password update request.
data PasswordUpdate = PasswordUpdate {
    pwdOld :: !SpendingPassword
  , pwdNew :: !SpendingPassword
  } deriving (Show, Eq, Generic)

deriveJSON Aeson.defaultOptions ''PasswordUpdate

instance ToSchema PasswordUpdate where
  declareNamedSchema =
    genericSchemaDroppingPrefix "pwd" (\(--^) props -> props
      & ("old" --^ "Old password.")
      & ("new" --^ "New passowrd.")
    )

instance Arbitrary PasswordUpdate where
  arbitrary = PasswordUpdate <$> arbitrary
                             <*> arbitrary

deriveSafeBuildable ''PasswordUpdate
instance BuildableSafeGen PasswordUpdate where
    buildSafeGen sl PasswordUpdate{..} = bprint("{"
        %" old="%buildSafe sl
        %" new="%buildSafe sl
        %" }")
        pwdOld
        pwdNew


-- | 'EstimatedFees' represents the fees which would be generated
-- for a 'Payment' in case the latter would actually be performed.
data EstimatedFees = EstimatedFees {
    feeEstimatedAmount :: !(V1 Core.Coin)
  } deriving (Show, Eq, Generic)

deriveJSON Aeson.defaultOptions ''EstimatedFees

instance ToSchema EstimatedFees where
  declareNamedSchema =
    genericSchemaDroppingPrefix "fee" (\(--^) props -> props
      & ("estimatedAmount" --^ "Estimated fees, in Entropic.")
    )

instance Arbitrary EstimatedFees where
  arbitrary = EstimatedFees <$> arbitrary

deriveSafeBuildable ''EstimatedFees
instance BuildableSafeGen EstimatedFees where
    buildSafeGen sl EstimatedFees{..} = bprint("{"
        %" estimatedAmount="%buildSafe sl
        %" }")
        feeEstimatedAmount


-- | Maps an 'Address' to some 'Coin's, and it's
-- typically used to specify where to send money during a 'Payment'.
data PaymentDistribution = PaymentDistribution {
      pdAddress :: !(V1 Core.Address)
    , pdAmount  :: !(V1 Core.Coin)
    } deriving (Show, Ord, Eq, Generic)

deriveJSON Aeson.defaultOptions ''PaymentDistribution

instance ToSchema PaymentDistribution where
  declareNamedSchema =
    genericSchemaDroppingPrefix "pd" (\(--^) props -> props
      & ("address" --^ "Address to map coins to.")
      & ("amount"  --^ "Amount of coin to bind, in Entropic.")
    )

instance Arbitrary PaymentDistribution where
  arbitrary = PaymentDistribution <$> arbitrary
                                  <*> arbitrary

deriveSafeBuildable ''PaymentDistribution
instance BuildableSafeGen PaymentDistribution where
    buildSafeGen sl PaymentDistribution{..} = bprint ("{"
        %" address="%buildSafe sl
        %" amount="%buildSafe sl
        %" }")
        pdAddress
        pdAmount


-- | A 'PaymentSource' encapsulate two essentially piece of data to reach for some funds:
-- a 'WalletId' and an 'AccountIndex' within it.
data PaymentSource = PaymentSource
  { psWalletId     :: !WalletId
  , psAccountIndex :: !AccountIndex
  } deriving (Show, Ord, Eq, Generic)

deriveJSON Aeson.defaultOptions ''PaymentSource

instance ToSchema PaymentSource where
  declareNamedSchema =
    genericSchemaDroppingPrefix "ps" (\(--^) props -> props
      & ("walletId"     --^ "Target wallet identifier to reach.")
      & ("accountIndex" --^ "Corresponding account's index on the wallet.")
    )

instance Arbitrary PaymentSource where
  arbitrary = PaymentSource <$> arbitrary
                            <*> arbitrary

deriveSafeBuildable ''PaymentSource
instance BuildableSafeGen PaymentSource where
    buildSafeGen sl PaymentSource{..} = bprint ("{"
        %" walletId="%buildSafe sl
        %" accountIndex="%buildSafe sl
        %" }")
        psWalletId
        psAccountIndex


-- | A 'Payment' from one source account to one or more 'PaymentDistribution'(s).
data Payment = Payment
  { pmtSource           :: !PaymentSource
  , pmtDestinations     :: !(NonEmpty PaymentDistribution)
  , pmtGroupingPolicy   :: !(Maybe (V1 Core.InputSelectionPolicy))
  , pmtSpendingPassword :: !(Maybe SpendingPassword)
  } deriving (Show, Eq, Generic)

instance ToJSON (V1 Core.InputSelectionPolicy) where
    toJSON (V1 Core.OptimizeForSecurity)       = String "OptimizeForSecurity"
    toJSON (V1 Core.OptimizeForHighThroughput) = String "OptimizeForHighThroughput"

instance FromJSON (V1 Core.InputSelectionPolicy) where
    parseJSON (String "OptimizeForSecurity")       = pure (V1 Core.OptimizeForSecurity)
    parseJSON (String "OptimizeForHighThroughput") = pure (V1 Core.OptimizeForHighThroughput)
    parseJSON x = typeMismatch "Not a valid InputSelectionPolicy" x

instance ToSchema (V1 Core.InputSelectionPolicy) where
    declareNamedSchema _ =
        pure $ NamedSchema (Just "V1InputSelectionPolicy") $ mempty
            & type_ ?~ SwaggerString
            & enum_ ?~ ["OptimizeForSecurity", "OptimizeForHighThroughput"]

instance Arbitrary (V1 Core.InputSelectionPolicy) where
    arbitrary = fmap V1 arbitrary


deriveJSON Aeson.defaultOptions ''Payment

instance Arbitrary Payment where
  arbitrary = Payment <$> arbitrary
                      <*> arbitrary
                      <*> arbitrary
                      <*> arbitrary

instance ToSchema Payment where
  declareNamedSchema =
    genericSchemaDroppingPrefix "pmt" (\(--^) props -> props
      & ("source"           --^ "Source for the payment.")
      & ("destinations"     --^ "One or more destinations for the payment.")
      & ("groupingPolicy"   --^ "Optional strategy to use for selecting the transaction inputs.")
      & ("spendingPassword" --^ "Wallet's protection password, required to spend funds if defined.")
    )

deriveSafeBuildable ''Payment
instance BuildableSafeGen Payment where
    buildSafeGen sl (Payment{..}) = bprint ("{"
        %" source="%buildSafe sl
        %" destinations="%buildSafeList sl
        %" groupingPolicty="%build
        %" spendingPassword="%(buildSafeMaybe mempty sl)
        %" }")
        pmtSource
        (toList pmtDestinations)
        pmtGroupingPolicy
        pmtSpendingPassword

----------------------------------------------------------------------------
-- TxId
----------------------------------------------------------------------------
instance Arbitrary (V1 Txp.TxId) where
  arbitrary = V1 <$> arbitrary

instance ToJSON (V1 Txp.TxId) where
  toJSON (V1 t) = String (sformat hashHexF t)

instance FromJSON (V1 Txp.TxId) where
    parseJSON = withText "TxId" $ \t -> do
       case decodeHash t of
           Left err -> fail $ "Failed to parse transaction ID: " <> toString err
           Right a  -> pure (V1 a)

instance FromHttpApiData (V1 Txp.TxId) where
    parseQueryParam = fmap (fmap V1) decodeHash

instance ToHttpApiData (V1 Txp.TxId) where
    toQueryParam (V1 txId) = sformat hashHexF txId

instance ToSchema (V1 Txp.TxId) where
    declareNamedSchema _ = declareNamedSchema (Proxy @Text)

----------------------------------------------------------------------------
  -- Transaction types
----------------------------------------------------------------------------

-- | The 'Transaction' type.
data TransactionType =
    LocalTransaction
  -- ^ This transaction is local, which means all the inputs
  -- and all the outputs belongs to the wallet from which the
  -- transaction was originated.
  | ForeignTransaction
  -- ^ This transaction is not local to this wallet.
  deriving (Show, Ord, Eq, Enum, Bounded)

instance Arbitrary TransactionType where
  arbitrary = elements [minBound .. maxBound]

-- Drops the @Transaction@ suffix.
deriveJSON defaultOptions { A.constructorTagModifier = reverse . drop 11 . reverse . map C.toLower
                          } ''TransactionType

instance ToSchema TransactionType where
    declareNamedSchema _ =
        pure $ NamedSchema (Just "TransactionType") $ mempty
            & type_ ?~ SwaggerString
            & enum_ ?~ ["local", "foreign"]
            & description ?~ mconcat
                [ "A transaction is 'local' if all the inputs and outputs "
                , "belong to the current wallet. A transaction is foreign "
                , "if the transaction is not local to this wallet."
                ]

deriveSafeBuildable ''TransactionType
instance BuildableSafeGen TransactionType where
    buildSafeGen _ LocalTransaction   = "local"
    buildSafeGen _ ForeignTransaction = "foreign"


-- | The 'Transaction' @direction@
data TransactionDirection =
    IncomingTransaction
  -- ^ This represents an incoming transactions.
  | OutgoingTransaction
  -- ^ This qualifies external transactions.
  deriving (Show, Ord, Eq, Enum, Bounded)

instance Arbitrary TransactionDirection where
  arbitrary = elements [minBound .. maxBound]

-- Drops the @Transaction@ suffix.
deriveJSON defaultOptions { A.constructorTagModifier = reverse . drop 11 . reverse . map C.toLower
                          } ''TransactionDirection

instance ToSchema TransactionDirection where
    declareNamedSchema _ =
        pure $ NamedSchema (Just "TransactionDirection") $ mempty
            & type_ ?~ SwaggerString
            & enum_ ?~ ["outgoing", "incoming"]

-- | This is an information-less variant of 'PtxCondition'.
data TransactionStatus
    = Applying
    | InNewestBlocks
    | Persisted
    | WontApply
    | Creating
    deriving (Eq, Show, Ord)

allTransactionStatuses :: [TransactionStatus]
allTransactionStatuses =
    [Applying, InNewestBlocks, Persisted, WontApply, Creating]

transactionStatusToText :: TransactionStatus -> Text
transactionStatusToText x = case x of
    Applying {} ->
        "applying"
    InNewestBlocks {} ->
        "inNewestBlocks"
    Persisted {} ->
        "persisted"
    WontApply {} ->
        "wontApply"
    Creating {} ->
        "creating"

instance ToJSON TransactionStatus where
    toJSON x = object
        [ "tag" .= transactionStatusToText x
        , "data" .= Object mempty
        ]

instance ToSchema TransactionStatus where
    declareNamedSchema _ =
        pure $ NamedSchema (Just "TransactionStatus") $ mempty
            & type_ ?~ SwaggerObject
            & required .~ ["tag", "data"]
            & properties .~ (mempty
                & at "tag" ?~ Inline (mempty
                    & type_ ?~ SwaggerString
                    & enum_ ?~
                        map (String . transactionStatusToText)
                            allTransactionStatuses
                )
                & at "data" ?~ Inline (mempty
                    & type_ ?~ SwaggerObject
                )
            )

instance FromJSON TransactionStatus where
    parseJSON = withObject "TransactionStatus" $ \o -> do
       tag <- o .: "tag"
       case tag of
           "applying" ->
                pure Applying
           "inNewestBlocks" ->
                pure InNewestBlocks
           "persisted" ->
                pure Persisted
           "wontApply" ->
                pure WontApply
           "creating" ->
                pure Creating
           _ ->
                fail $ "Couldn't parse out of " ++ toString (tag :: Text)

instance Arbitrary TransactionStatus where
    arbitrary = elements allTransactionStatuses

deriveSafeBuildable ''TransactionDirection
instance BuildableSafeGen TransactionDirection where
    buildSafeGen _ IncomingTransaction = "incoming"
    buildSafeGen _ OutgoingTransaction = "outgoing"

-- | A 'Wallet''s 'Transaction'.
data Transaction = Transaction
  { txId            :: !(V1 Txp.TxId)
  , txConfirmations :: !Word
  , txAmount        :: !(V1 Core.Coin)
  , txInputs        :: !(NonEmpty PaymentDistribution)
  , txOutputs       :: !(NonEmpty PaymentDistribution)
    -- ^ The output money distribution.
  , txType          :: !TransactionType
    -- ^ The type for this transaction (e.g local, foreign, etc).
  , txDirection     :: !TransactionDirection
    -- ^ The direction for this transaction (e.g incoming, outgoing).
  , txCreationTime  :: !(V1 Core.Timestamp)
    -- ^ The time when transaction was created.
  , txStatus        :: !TransactionStatus
  } deriving (Show, Ord, Eq, Generic)

deriveJSON Aeson.defaultOptions ''Transaction

instance ToSchema Transaction where
  declareNamedSchema =
    genericSchemaDroppingPrefix "tx" (\(--^) props -> props
      & ("id"            --^ "Transaction's id.")
      & ("confirmations" --^ "Number of confirmations.")
      & ("amount"        --^ "Coins moved as part of the transaction, in Entropic.")
      & ("inputs"        --^ "One or more input money distributions.")
      & ("outputs"       --^ "One or more ouputs money distributions.")
      & ("type"          --^ "Whether the transaction is entirely local or foreign.")
      & ("direction"     --^ "Direction for this transaction.")
      & ("creationTime"  --^ "Timestamp indicating when the transaction was created.")
      & ("status"        --^ "Shows whether or not the transaction is accepted.")
    )

instance Arbitrary Transaction where
  arbitrary = Transaction <$> arbitrary
                          <*> arbitrary
                          <*> arbitrary
                          <*> arbitrary
                          <*> arbitrary
                          <*> arbitrary
                          <*> arbitrary
                          <*> arbitrary
                          <*> arbitrary

deriveSafeBuildable ''Transaction
instance BuildableSafeGen Transaction where
    buildSafeGen sl Transaction{..} = bprint ("{"
        %" id="%buildSafe sl
        %" confirmations="%build
        %" amount="%buildSafe sl
        %" inputs="%buildSafeList sl
        %" outputs="%buildSafeList sl
        %" type="%buildSafe sl
        %" direction"%buildSafe sl
        %" }")
        txId
        txConfirmations
        txAmount
        (toList txInputs)
        (toList txOutputs)
        txType
        txDirection

instance Buildable [Transaction] where
    build = bprint listJson

-- | A type representing an upcoming wallet update.
data WalletSoftwareUpdate = WalletSoftwareUpdate
  { updSoftwareVersion   :: !Text
  , updBlockchainVersion :: !Text
  , updScriptVersion     :: !Int
  -- Other types omitted for now.
  } deriving (Show, Eq, Generic)

deriveJSON Aeson.defaultOptions ''WalletSoftwareUpdate

instance ToSchema WalletSoftwareUpdate where
  declareNamedSchema =
    genericSchemaDroppingPrefix "upd" (\(--^) props -> props
      & ("softwareVersion"   --^ "Current software (wallet) version.")
      & ("blockchainVersion" --^ "Version of the underlying blockchain.")
      & ("scriptVersion"     --^ "Update script version.")
    )

instance Arbitrary WalletSoftwareUpdate where
  arbitrary = WalletSoftwareUpdate <$> arbitrary
                                   <*> arbitrary
                                   <*> fmap getPositive arbitrary

deriveSafeBuildable ''WalletSoftwareUpdate
instance BuildableSafeGen WalletSoftwareUpdate where
    buildSafeGen _ WalletSoftwareUpdate{..} = bprint("{"
        %" softwareVersion="%build
        %" blockchainVersion="%build
        %" scriptVersion="%build
        %" }")
        updSoftwareVersion
        updBlockchainVersion
        updScriptVersion

-- | A type encapsulating enough information to import a wallet from a
-- backup file.
data WalletImport = WalletImport
  { wiSpendingPassword :: !(Maybe SpendingPassword)
  , wiFilePath         :: !FilePath
  } deriving (Show, Eq, Generic)

deriveJSON Aeson.defaultOptions ''WalletImport

instance ToSchema WalletImport where
  declareNamedSchema =
    genericSchemaDroppingPrefix "wi" (\(--^) props -> props
      & ("spendingPassword"   --^ "An optional spending password to set for the imported wallet.")
      & ("filePath" --^ "The path to the .key file holding the backup.")
    )

instance Arbitrary WalletImport where
  arbitrary = WalletImport <$> arbitrary
                           <*> arbitrary

deriveSafeBuildable ''WalletImport
instance BuildableSafeGen WalletImport where
    buildSafeGen sl WalletImport{..} = bprint("{"
        %" spendingPassword="%build
        %" filePath="%build
        %" }")
        (maybe "null" (buildSafeGen sl) wiSpendingPassword)
        wiFilePath

-- | A redemption mnemonic.
newtype RedemptionMnemonic = RedemptionMnemonic
    { unRedemptionMnemonic :: Mnemonic 9
    }
    deriving stock (Eq, Show, Generic)
    deriving newtype (ToJSON, FromJSON, Arbitrary)

instance ToSchema RedemptionMnemonic where
    declareNamedSchema _ = pure $
        NamedSchema (Just "RedemptionMnemonic") (toSchema (Proxy @(Mnemonic 9)))

-- | A shielded redemption code.
newtype ShieldedRedemptionCode = ShieldedRedemptionCode
    { unShieldedRedemptionCode :: Text
    } deriving (Eq, Show, Generic)
      deriving newtype (ToJSON, FromJSON)

-- | This instance could probably be improved. A 'ShieldedRedemptionCode' is
-- a hash of the redemption key.
instance Arbitrary ShieldedRedemptionCode where
    arbitrary = ShieldedRedemptionCode <$> arbitrary

instance ToSchema ShieldedRedemptionCode where
    declareNamedSchema _ =
        pure
            $ NamedSchema (Just "ShieldedRedemptionCode") $ mempty
            & type_ ?~ SwaggerString

deriveSafeBuildable ''ShieldedRedemptionCode
instance BuildableSafeGen ShieldedRedemptionCode where
    buildSafeGen _ _ =
        bprint "<shielded redemption code>"

-- | The request body for redeeming some Bcc.
data Redemption = Redemption
    { redemptionRedemptionCode   :: ShieldedRedemptionCode
    -- ^ The redemption code associated with the Bcc to redeem.
    , redemptionMnemonic         :: Maybe RedemptionMnemonic
    -- ^ An optional mnemonic. This mnemonic was included with paper
    -- certificates, and the presence of this field indicates that we're
    -- doing a paper vend.
    , redemptionSpendingPassword :: SpendingPassword
    -- ^ The user must provide a spending password that matches the wallet that
    -- will be receiving the redemption funds.
    , redemptionWalletId         :: WalletId
    -- ^ Redeem to this wallet
    , redemptionAccountIndex     :: AccountIndex
    -- ^ Redeem to this account index in the wallet
    } deriving (Eq, Show, Generic)

deriveSafeBuildable ''Redemption
instance BuildableSafeGen Redemption where
    buildSafeGen sl r = bprint ("{"
        %" redemptionCode="%buildSafe sl
        %" mnemonic=<mnemonic>"
        %" spendingPassword="%buildSafe sl
        %" }")
        (redemptionRedemptionCode r)
        (redemptionSpendingPassword r)

deriveJSON Aeson.defaultOptions ''Redemption

instance ToSchema Redemption where
    declareNamedSchema =
        genericSchemaDroppingPrefix "redemption" (\(--^) props -> props
            & "redemptionCode"
            --^ "The redemption code associated with the Bcc to redeem."
            & "mnemonic"
            --^ ( "An optional mnemonic. This must be provided for a paper "
                <> "certificate redemption."
                )
            & "spendingPassword"
            --^ ( "An optional spending password. This must match the password "
                <> "for the provided wallet ID and account index."
                )
        )

instance Arbitrary Redemption where
    arbitrary = Redemption <$> arbitrary
                           <*> arbitrary
                           <*> arbitrary
                           <*> arbitrary
                           <*> arbitrary

--
-- POST/PUT requests isomorphisms
--

type family Update (original :: *) :: * where
    Update Wallet =
        WalletUpdate
    Update Account =
        AccountUpdate
    Update WalletAddress =
        () -- read-only

type family New (original :: *) :: * where
    New Wallet =
        NewWallet
    New Account =
        NewAccount
    New WalletAddress =
        NewAddress

type CaptureWalletId = Capture "walletId" WalletId

type CaptureAccountId = Capture "accountId" AccountIndex

--
-- Example typeclass instances
--

instance Example Core.Address
instance Example AccountIndex
instance Example AccountBalance
instance Example AccountAddresses
instance Example WalletId
instance Example AssuranceLevel
instance Example LocalTimeDifference
instance Example PaymentDistribution
instance Example AccountUpdate
instance Example Wallet
instance Example WalletUpdate
instance Example WalletOperation
instance Example PasswordUpdate
instance Example EstimatedFees
instance Example Transaction
instance Example WalletSoftwareUpdate
instance Example WalletAddress
instance Example NewAccount
instance Example AddressValidity
instance Example NewAddress
instance Example ShieldedRedemptionCode
instance Example (V1 Core.PassPhrase)
instance Example (V1 Core.Coin)

-- | We have a specific 'Example' instance for @'V1' 'Address'@ because we want
-- to control the length of the examples. It is possible for the encoded length
-- to become huge, up to 1000+ bytes, if the 'UnsafeMultiKeyDistr' constructor
-- is used. We do not use this constructor, which keeps the address between
-- ~80-150 bytes long.
instance Example (V1 Core.Address) where
    example = fmap V1 . Core.makeAddress
        <$> arbitrary
        <*> arbitraryAttributes
      where
        arbitraryAttributes =
            Core.AddrAttributes
                <$> arbitrary
                <*> oneof
                    [ pure Core.BootstrapEraDistr
                    , Core.SingleKeyDistr <$> arbitrary
                    ]
                <*> arbitrary

instance Example BackupPhrase where
    example = pure (BackupPhrase def)

instance Example Core.InputSelectionPolicy where
    example = pure Core.OptimizeForHighThroughput

instance Example (V1 Core.InputSelectionPolicy) where
    example = pure (V1 Core.OptimizeForHighThroughput)

instance Example Account where
    example = Account <$> example
                      <*> example -- NOTE: this will produce non empty list
                      <*> example
                      <*> pure "My account"
                      <*> example

instance Example NewWallet where
    example = NewWallet <$> example
                        <*> example -- Note: will produce `Just a`
                        <*> example
                        <*> pure "My Wallet"
                        <*> example

instance Example PublicKey where
    example = PublicKey <$> pure xpub
      where
        xpub = rights
            [ CC.xpub
            . fromJust
            . decodeBase58 bitcoinAlphabet
            . encodeUtf8 $ encodedPublicKey
            ] !! 0

        encodedPublicKey :: Text
        encodedPublicKey =
            "bNfWjshJG9xxy6VkpV2KurwGah3jQWjGb4QveDGZteaCwupdKWAi371r8uS5yFCny5i5EQuSNSLKqvRHmWEoHe45pZ"

instance Example PaymentSource where
    example = PaymentSource <$> example
                            <*> example

instance Example Payment where
    example = Payment <$> example
                      <*> example
                      <*> example -- TODO: will produce `Just groupingPolicy`
                      <*> example

instance Example Redemption where
    example = Redemption <$> example
                         <*> pure Nothing
                         <*> example
                         <*> example
                         <*> example

instance Example WalletImport where
    example = WalletImport <$> example
                           <*> pure "/Users/foo/Documents/wallet_to_import.key"

--
-- Wallet Errors
--

-- | Details about what 'NotEnoughMoney' means
data ErrNotEnoughMoney
    -- | UTxO exhausted whilst trying to pick inputs to cover remaining fee
    = ErrCannotCoverFee

    -- | UTxO exhausted during input selection
    --
    -- We record the available balance of the UTxO
    | ErrAvailableBalanceIsInsufficient Int

    deriving (Eq, Show, Generic)

instance Buildable ErrNotEnoughMoney where
    build = \case
        ErrCannotCoverFee ->
             bprint "Not enough coins to cover fee."
        ErrAvailableBalanceIsInsufficient _ ->
             bprint "Not enough available coins to proceed."

instance ToJSON ErrNotEnoughMoney where
    toJSON = \case
        e@ErrCannotCoverFee -> object
            [ "msg" .= sformat build e
            ]
        e@(ErrAvailableBalanceIsInsufficient balance) -> object
            [ "msg"              .= sformat build e
            , "availableBalance" .= balance
            ]

instance FromJSON ErrNotEnoughMoney where
    parseJSON v =
            withObject "AvailableBalanceIsInsufficient" availableBalanceIsInsufficientParser v
        <|> withObject "CannotCoverFee" cannotCoverFeeParser v
      where
        cannotCoverFeeParser :: Object -> Parser ErrNotEnoughMoney
        cannotCoverFeeParser o = do
            msg <- o .: "msg"
            when (msg /= sformat build ErrCannotCoverFee) mempty
            pure ErrCannotCoverFee

        availableBalanceIsInsufficientParser :: Object -> Parser ErrNotEnoughMoney
        availableBalanceIsInsufficientParser o = do
            msg <- o .: "msg"
            when (msg /= sformat build (ErrAvailableBalanceIsInsufficient 0)) mempty
            ErrAvailableBalanceIsInsufficient <$> (o .: "availableBalance")

data ErrUtxoNotEnoughFragmented = ErrUtxoNotEnoughFragmented {
      theMissingUtxos :: !Int
    , theHelp         :: !Text
    } deriving (Eq, Generic, Show)


msgUtxoNotEnoughFragmented :: Text
msgUtxoNotEnoughFragmented = "Utxo is not enough fragmented to handle the number of outputs of this transaction. Query /api/v1/wallets/{walletId}/statistics/utxos endpoint for more information"

deriveJSON Aeson.defaultOptions ''ErrUtxoNotEnoughFragmented

instance Buildable ErrUtxoNotEnoughFragmented where
    build (ErrUtxoNotEnoughFragmented missingUtxos _ ) =
        bprint ("Missing "%build%" utxo(s) to accommodate all outputs of the transaction") missingUtxos


-- | Type representing any error which might be thrown by wallet.
--
-- Errors are represented in JSON in the JSend format (<https://labs.omniti.com/labs/jsend>):
-- ```
-- {
--     "status": "error"
--     "message" : <constr_name>,
--     "diagnostic" : <data>
-- }
-- ```
-- where `<constr_name>` is a string containing name of error's constructor (e. g. `NotEnoughMoney`),
-- and `<data>` is an object containing additional error data.
-- Additional data contains constructor fields, field names are record field names without
-- a `we` prefix, e. g. for `OutputIsRedeem` error "diagnostic" field will be the following:
-- ```
-- {
--     "address" : <address>
-- }
-- ```
--
-- Additional data in constructor should be represented as record fields.
-- Otherwise TemplateHaskell will raise an error.
--
-- If constructor does not have additional data (like in case of `WalletNotFound` error),
-- then "diagnostic" field will be empty object.
--
-- TODO: change fields' types to actual Bcc core types, like `Coin` and `Address`
data WalletError =
    -- | NotEnoughMoney weNeedMore
      NotEnoughMoney !ErrNotEnoughMoney
    -- | OutputIsRedeem weAddress
    | OutputIsRedeem !(V1 Core.Address)
    -- | UnknownError weMsg
    | UnknownError !Text
    -- | InvalidAddressFormat weMsg
    | InvalidAddressFormat !Text
    | WalletNotFound
    | WalletAlreadyExists !WalletId
    | AddressNotFound
    | TxFailedToStabilize
    | InvalidPublicKey !Text
    | UnsignedTxCreationError
    | TooBigTransaction
    -- ^ Size of transaction (in bytes) is greater than maximum.
    | SignedTxSubmitError !Text
    | TxRedemptionDepleted
    -- | TxSafeSignerNotFound weAddress
    | TxSafeSignerNotFound !(V1 Core.Address)
    -- | MissingRequiredParams requiredParams
    | MissingRequiredParams !(NonEmpty (Text, Text))
    -- | WalletIsNotReadyToProcessPayments weStillRestoring
    | CannotCreateAddress !Text
    -- ^ Cannot create derivation path for new address (for external wallet).
    | WalletIsNotReadyToProcessPayments !SyncProgress
    -- ^ The @Wallet@ where a @Payment@ is being originated is not fully
    -- synced (its 'WalletSyncState' indicates it's either syncing or
    -- restoring) and thus cannot accept new @Payment@ requests.
    -- | NodeIsStillSyncing wenssStillSyncing
    | NodeIsStillSyncing !SyncPercentage
    -- ^ The backend couldn't process the incoming request as the underlying
    -- node is still syncing with the blockchain.
    | RequestThrottled !Word64
    -- ^ The request has been throttled. The 'Word64' is a count of microseconds
    -- until the user should retry.
    | UtxoNotEnoughFragmented !ErrUtxoNotEnoughFragmented
    -- ^ available Utxo is not enough fragmented, ie., there is more outputs of transaction than
    -- utxos
    deriving (Generic, Show, Eq)

deriveGeneric ''WalletError

instance Exception WalletError

instance ToHttpErrorStatus WalletError

instance ToJSON WalletError where
    toJSON = jsendErrorGenericToJSON

instance FromJSON WalletError where
    parseJSON = jsendErrorGenericParseJSON

instance Arbitrary WalletError where
    arbitrary = Gen.oneof
        [ NotEnoughMoney <$> Gen.oneof
            [ pure ErrCannotCoverFee
            , ErrAvailableBalanceIsInsufficient <$> Gen.choose (1, 1000)
            ]
        , OutputIsRedeem . V1 <$> arbitrary
        , UnknownError <$> arbitraryText
        , InvalidAddressFormat <$> arbitraryText
        , pure WalletNotFound
        , WalletAlreadyExists <$> arbitrary
        , pure AddressNotFound
        , InvalidPublicKey <$> arbitraryText
        , pure UnsignedTxCreationError
        , SignedTxSubmitError <$> arbitraryText
        , pure TooBigTransaction
        , pure TxFailedToStabilize
        , pure TxRedemptionDepleted
        , TxSafeSignerNotFound . V1 <$> arbitrary
        , MissingRequiredParams <$> Gen.oneof
            [ unsafeMkNonEmpty <$> Gen.vectorOf 1 arbitraryParam
            , unsafeMkNonEmpty <$> Gen.vectorOf 2 arbitraryParam
            , unsafeMkNonEmpty <$> Gen.vectorOf 3 arbitraryParam
            ]
        , WalletIsNotReadyToProcessPayments <$> arbitrary
        , NodeIsStillSyncing <$> arbitrary
        , CannotCreateAddress <$> arbitraryText
        , RequestThrottled <$> arbitrary
        , UtxoNotEnoughFragmented <$> Gen.oneof
          [ ErrUtxoNotEnoughFragmented <$> Gen.choose (1, 10) <*> arbitrary
          ]
        ]
      where
        arbitraryText :: Gen Text
        arbitraryText =
            toText . Gen.getASCIIString <$> arbitrary

        arbitraryParam :: Gen (Text, Text)
        arbitraryParam =
            (,) <$> arbitrary <*> arbitrary

        unsafeMkNonEmpty :: [a] -> NonEmpty a
        unsafeMkNonEmpty (h:q) = h :| q
        unsafeMkNonEmpty _     = error "unsafeMkNonEmpty called with empty list"


-- | Give a short description of an error
instance Buildable WalletError where
    build = \case
        NotEnoughMoney x ->
             bprint build x
        OutputIsRedeem _ ->
             bprint "One of the TX outputs is a redemption address."
        UnknownError _ ->
             bprint "Unexpected internal error."
        InvalidAddressFormat _ ->
             bprint "Provided address format is not valid."
        WalletNotFound ->
             bprint "Reference to an unexisting wallet was given."
        WalletAlreadyExists _ ->
             bprint "Can't create or restore a wallet. The wallet already exists."
        AddressNotFound ->
             bprint "Reference to an unexisting address was given."
        InvalidPublicKey _ ->
            bprint "Extended public key (for external wallet) is invalid."
        UnsignedTxCreationError ->
            bprint "Unable to create unsigned transaction for an external wallet."
        TooBigTransaction ->
            bprint "Transaction size is greater than 4096 bytes."
        SignedTxSubmitError _ ->
            bprint "Unable to submit externally-signed transaction."
        MissingRequiredParams _ ->
            bprint "Missing required parameters in the request payload."
        WalletIsNotReadyToProcessPayments _ ->
            bprint "This wallet is restoring, and it cannot send new transactions until restoration completes."
        NodeIsStillSyncing _ ->
            bprint "The node is still syncing with the blockchain, and cannot process the request yet."
        TxRedemptionDepleted ->
            bprint "The redemption address was already used."
        TxSafeSignerNotFound _ ->
            bprint "The safe signer at the specified address was not found."
        TxFailedToStabilize ->
            bprint "We were unable to find a set of inputs to satisfy this transaction."
        CannotCreateAddress _ ->
            bprint "Cannot create derivation path for new address, for external wallet."
        RequestThrottled _ ->
            bprint "You've made too many requests too soon, and this one was throttled."
        UtxoNotEnoughFragmented x ->
            bprint build x

-- | Convert wallet errors to Servant errors
instance ToServantError WalletError where
    declareServantError = \case
        NotEnoughMoney{} ->
            err403
        OutputIsRedeem{} ->
            err403
        UnknownError{} ->
            err500
        WalletNotFound{} ->
            err404
        WalletAlreadyExists{} ->
            err403
        InvalidAddressFormat{} ->
            err401
        AddressNotFound{} ->
            err404
        InvalidPublicKey{} ->
            err400
        UnsignedTxCreationError{} ->
            err500
        TooBigTransaction{} ->
            err400
        SignedTxSubmitError{} ->
            err500
        MissingRequiredParams{} ->
            err400
        WalletIsNotReadyToProcessPayments{} ->
            err403
        NodeIsStillSyncing{} ->
            err412 -- Precondition failed
        TxFailedToStabilize{} ->
            err500
        TxRedemptionDepleted{} ->
            err400
        TxSafeSignerNotFound{} ->
            err400
        CannotCreateAddress{} ->
            err500
        RequestThrottled{} ->
            err400 { errHTTPCode = 429 }
        UtxoNotEnoughFragmented{} ->
            err403

-- | Declare the key used to wrap the diagnostic payload, if any
instance HasDiagnostic WalletError where
    getDiagnosticKey = \case
        NotEnoughMoney{} ->
            "details"
        OutputIsRedeem{} ->
            "address"
        UnknownError{} ->
            "msg"
        WalletNotFound{} ->
            noDiagnosticKey
        WalletAlreadyExists{} ->
            "walletId"
        InvalidAddressFormat{} ->
            "msg"
        AddressNotFound{} ->
            noDiagnosticKey
        InvalidPublicKey{} ->
            "msg"
        UnsignedTxCreationError{} ->
            noDiagnosticKey
        TooBigTransaction{} ->
            noDiagnosticKey
        SignedTxSubmitError{} ->
            "msg"
        MissingRequiredParams{} ->
            "params"
        WalletIsNotReadyToProcessPayments{} ->
            "stillRestoring"
        NodeIsStillSyncing{} ->
            "stillSyncing"
        TxFailedToStabilize{} ->
            noDiagnosticKey
        TxRedemptionDepleted{} ->
            noDiagnosticKey
        TxSafeSignerNotFound{} ->
            "address"
        CannotCreateAddress{} ->
            "msg"
        RequestThrottled{} ->
            "microsecondsUntilRetry"
        UtxoNotEnoughFragmented{} ->
            "details"
