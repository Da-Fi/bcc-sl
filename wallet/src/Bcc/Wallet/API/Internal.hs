-- | This module contains the top level API definition for frontend-related
-- tasks.  The API endpoints presented here are intended for use with the
-- Bezalel client, and aren't useful for wallets, exchanges, and other users.
module Bcc.Wallet.API.Internal where

import Prelude

import           Pos.Chain.Update (SoftwareVersion)

import           Servant

import           Bcc.Wallet.API.Response (APIResponse, ValidJSON)
import           Bcc.Wallet.API.Types
import           Bcc.Wallet.API.V1.Types (V1, Wallet, WalletImport, BackupPhrase, MnemonicBalance)

type API = Tag "Internal" ('TagDescription
    "This section contains endpoints so-called 'Internal'. They are only\
    \ expected to be used by advanced users of the API (e.g. Bezalel) with\
    \ which there's a privileged communication channel. Backward-compatibility\
    \ or existence of these endpoints between versions is not guaranteed and\
    \ won't be enforced. Use at your own risks.")
    :>
    (    "next-update"
        :> Summary "Version of the next update (404 if none)"
        :> Get '[ValidJSON] (APIResponse (V1 SoftwareVersion))

    :<|> "apply-update"
        :> Summary "Apply the next available update"
        :> Post '[ValidJSON] NoContent

    :<|> "postpone-update"
        :> Summary "Discard and postpone the next available update"
        :> Post '[ValidJSON] NoContent

    :<|> "reset-wallet-state"
        :> Summary "Clear wallet state and all associated secret keys"
        :> DeleteNoContent '[ValidJSON] NoContent
    :<|> "import-wallet"
        :> Summary "Import a Wallet from disk."
        :> ReqBody '[ValidJSON] WalletImport
        :> Post '[ValidJSON] (APIResponse Wallet)
    :<|> "calculate_mnemonic"
        :> Summary "calculates the walletid from a given mnemonic"
        :> QueryParam "read_balance" Bool
        :> ReqBody '[ValidJSON] BackupPhrase
        :> Post '[ValidJSON] (APIResponse MnemonicBalance)
    )
