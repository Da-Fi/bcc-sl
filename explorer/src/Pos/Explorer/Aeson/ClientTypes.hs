{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell    #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Pos.Explorer.Aeson.ClientTypes
       (
       ) where

import           Universum

import           Data.Aeson.Encoding (unsafeToEncoding)
import           Data.Aeson.TH (defaultOptions, deriveJSON, deriveToJSON)
import           Data.Aeson.Types (ToJSON (..))
import qualified Data.ByteString.Builder as BS (string8)
import           Data.Fixed (showFixed)

import           Pos.Explorer.Web.ClientTypes (CBcc (..), CAddress,
                     CAddressSummary, CAddressType, CBlockEntry, CBlockSummary,
                     CByteString (..), CCoin, CGenesisAddressInfo,
                     CGenesisSummary, CHash, CNetworkAddress, CTxBrief,
                     CTxEntry, CTxId, CTxSummary, CUtxo, CBlockRange)
import           Pos.Explorer.Web.Error (ExplorerError)

deriveJSON defaultOptions ''CHash
deriveJSON defaultOptions ''CAddress
deriveJSON defaultOptions ''CTxId

deriveToJSON defaultOptions ''CCoin
deriveToJSON defaultOptions ''ExplorerError
deriveToJSON defaultOptions ''CBlockEntry
deriveToJSON defaultOptions ''CTxEntry
deriveToJSON defaultOptions ''CTxBrief
deriveToJSON defaultOptions ''CAddressType
deriveToJSON defaultOptions ''CAddressSummary
deriveToJSON defaultOptions ''CBlockSummary
deriveToJSON defaultOptions ''CNetworkAddress
deriveToJSON defaultOptions ''CBlockRange
deriveToJSON defaultOptions ''CTxSummary
deriveToJSON defaultOptions ''CGenesisSummary
deriveToJSON defaultOptions ''CGenesisAddressInfo
deriveToJSON defaultOptions ''CUtxo

instance ToJSON CByteString where
    toJSON (CByteString bs) = (toJSON.toString) bs

instance ToJSON CBcc where
    -- https://github.com/bos/aeson/issues/227#issuecomment-245400284
    toEncoding (CBcc bcc) =
        showFixed True bcc & -- convert Micro to String chopping off trailing zeros
        BS.string8 &         -- convert String to ByteString using Latin1 encoding
        unsafeToEncoding     -- convert ByteString to Aeson's Encoding
