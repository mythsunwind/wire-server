{-# LANGUAGE PartialTypeSignatures #-}
{-# OPTIONS_GHC -Wno-partial-type-signatures -Wno-unused-imports #-}

-- This file is part of the Wire Server implementation.
--
-- Copyright (C) 2020 Wire Swiss GmbH <opensource@wire.com>
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU Affero General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option) any
-- later version.
--
-- This program is distributed in the hope that it will be useful, but WITHOUT
-- ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
-- FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
-- details.
--
-- You should have received a copy of the GNU Affero General Public License along
-- with this program. If not, see <https://www.gnu.org/licenses/>.

module Federator.InternalServer where

import Control.Lens (view)
import Data.Domain (Domain, domainText)
import Data.Either.Validation (Validation (..))
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.X509.CertificateStore
import Federator.App (Federator, runAppT)
import Federator.Discovery (DiscoverFederator, LookupError (LookupErrorDNSError, LookupErrorSrvNotAvailable), runFederatorDiscovery)
import Federator.Env (Env, applog, caStore, dnsResolver, runSettings)
import Federator.Options (RunSettings)
import Federator.Remote (Remote, RemoteError (..), discoverAndCall, handleLookupErrors, interpretRemote, logRemoteErrors)
import Federator.Utils.PolysemyServerError (absorbServerError)
import Federator.Validation
import Imports
import Mu.GRpc.Client.Record (GRpcReply (..))
import Mu.GRpc.Server (msgProtoBuf, runGRpcAppTrans)
import Mu.Server (ServerError, ServerErrorIO, SingleServerT, singleService)
import qualified Mu.Server as Mu
import Network.DNS.Resolver (Resolver)
import Polysemy
import qualified Polysemy.Error as Polysemy
import Polysemy.IO (embedToMonadIO)
import qualified Polysemy.Reader as Polysemy
import Polysemy.TinyLog (TinyLog)
import qualified Polysemy.TinyLog as Log
import Wire.API.Federation.GRPC.Types
import Wire.Network.DNS.Effect (DNSLookup)
import qualified Wire.Network.DNS.Effect as Lookup

callOutward :: Members '[Remote, Polysemy.Reader RunSettings] r => FederatedRequest -> Sem r OutwardResponse
callOutward req = do
  case validateFederatedRequest req of
    Success vReq -> do
      allowedRemote <- federateWith (vDomain vReq)
      if allowedRemote
        then replyToResponse <$> discoverAndCall vReq
        else pure $ mkOutwardErr FederationDeniedLocally "federation-not-allowed" ("federating with domain [" <> domainText (vDomain vReq) <> "] is not allowed (see federator configuration)")
    Failure errs ->
      pure $ mkOutwardErr InvalidRequest "invalid-request-to-federator" ("validation failed with: " <> Text.pack (show errs))

handleRemoteErrors ::
  Sem (Polysemy.Error RemoteError ': r) OutwardResponse ->
  Sem r OutwardResponse
handleRemoteErrors action =
  either remoteErrorToResponse id
    <$> Polysemy.runError action

-- FUTUREWORK(federation): Make these errors less stringly typed
remoteErrorToResponse :: RemoteError -> OutwardResponse
remoteErrorToResponse (RemoteErrorDiscoveryFailure domain err) = case err of
  LookupErrorSrvNotAvailable _srvDomain ->
    mkOutwardErr RemoteNotFound "srv-record-not-found" ("domain=" <> domainText domain)
  LookupErrorDNSError dnsErr ->
    mkOutwardErr DiscoveryFailed "srv-lookup-dns-error" ("domain=" <> domainText domain <> "; error=" <> Text.decodeUtf8 dnsErr)
remoteErrorToResponse (RemoteErrorClientFailure srvTarget cltErr) =
  mkOutwardErr RemoteFederatorError "cannot-connect-to-remote-federator" ("target=" <> Text.pack (show srvTarget) <> "; error=" <> Text.pack (show cltErr))
remoteErrorToResponse (RemoteErrorTLSException srvTarget exc) =
  mkOutwardErr TLSFailure "tls-failure" ("Failed to establish TLS session with remote:  target=" <> Text.pack (show srvTarget) <> "; exception=" <> Text.pack (show exc))

replyToResponse :: GRpcReply InwardResponse -> OutwardResponse
replyToResponse (GRpcOk (InwardResponseBody res)) = OutwardResponseBody res
replyToResponse (GRpcOk (InwardResponseError err)) = OutwardResponseInwardError err
replyToResponse (GRpcTooMuchConcurrency _) =
  mkOutwardErr
    RemoteFederatorError
    "too-much-concurrency"
    "Too much concurrency"
replyToResponse (GRpcErrorCode grpcErr) =
  mkOutwardErr
    RemoteFederatorError
    "grpc-error-code"
    ("code=" <> Text.pack (show grpcErr))
replyToResponse (GRpcErrorString grpcErr) =
  mkOutwardErr
    RemoteFederatorError
    "grpc-error-string"
    ("error=" <> Text.pack grpcErr)
replyToResponse (GRpcClientError clientErr) =
  mkOutwardErr
    RemoteFederatorError
    "grpc-client-error"
    ("error=" <> Text.pack (show clientErr))

mkOutwardErr :: OutwardErrorType -> Text -> Text -> OutwardResponse
mkOutwardErr typ label msg = OutwardResponseError $ OutwardError typ (Just $ ErrorPayload label msg)

interpretOutward ::
  Sem
    '[ Remote,
       Polysemy.Reader RunSettings,
       TinyLog,
       Polysemy.Error ServerError,
       Embed IO,
       Embed Federator
     ]
    OutwardResponse ->
  Federator OutwardResponse
interpretOutward action = do
  env <- ask
  runM
    . embedToMonadIO @Federator
    . absorbServerError
    . Log.runTinyLog (view applog env)
    . Polysemy.runReader (view runSettings env)
    . Polysemy.runReader (view caStore env)
    . handleRemoteErrors
    . logRemoteErrors
    . handleLookupErrors
    . Lookup.runDNSLookupWithResolver (view dnsResolver env)
    . runFederatorDiscovery
    . raiseUnder2
    . interpretRemote
    . raiseUnder3
    $ action

serveOutward :: Env -> Int -> IO ()
serveOutward env port = runGRpcAppTrans msgProtoBuf port (runAppT env) outward
  where
    outward :: SingleServerT info Outward Federator _
    outward = singleService (Mu.method @"call" (interpretOutward . callOutward))
