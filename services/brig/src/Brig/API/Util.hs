-- This file is part of the Wire Server implementation.
--
-- Copyright (C) 2022 Wire Swiss GmbH <opensource@wire.com>
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

module Brig.API.Util
  ( fetchUserIdentity,
    lookupProfilesMaybeFilterSameTeamOnly,
    lookupSelfProfile,
    logInvitationCode,
    validateHandle,
    logEmail,
    traverseConcurrentlyWithErrors,
    exceptTToMaybe,
    lookupSearchPolicy,
  )
where

import Brig.API.Error
import Brig.API.Handler
import Brig.API.Types
import Brig.App
import qualified Brig.Data.User as Data
import Brig.Options (FederationDomainConfig, federationDomainConfigs)
import qualified Brig.Options as Opts
import Brig.Types
import Brig.Types.Intra (accountUser)
import Control.Lens (view)
import Control.Monad.Catch (throwM)
import Control.Monad.Trans.Except
import Data.Domain (Domain)
import Data.Handle (Handle, parseHandle)
import Data.Id
import Data.Maybe
import Data.String.Conversions (cs)
import Data.Text.Ascii (AsciiText (toText))
import Imports
import System.Logger (Msg)
import qualified System.Logger as Log
import UnliftIO.Async
import UnliftIO.Exception (throwIO, try)
import Util.Logging (sha256String)
import Wire.API.Error
import Wire.API.Error.Brig
import Wire.API.User.Search (FederatedUserSearchPolicy (NoSearch))

lookupProfilesMaybeFilterSameTeamOnly :: UserId -> [UserProfile] -> (Handler r) [UserProfile]
lookupProfilesMaybeFilterSameTeamOnly self us = do
  selfTeam <- lift $ wrapClient $ Data.lookupUserTeam self
  return $ case selfTeam of
    Just team -> filter (\x -> profileTeam x == Just team) us
    Nothing -> us

fetchUserIdentity :: UserId -> (AppT r) (Maybe UserIdentity)
fetchUserIdentity uid =
  lookupSelfProfile uid
    >>= maybe
      (throwM $ UserProfileNotFound uid)
      (return . userIdentity . selfUser)

-- | Obtain a profile for a user as he can see himself.
lookupSelfProfile :: UserId -> (AppT r) (Maybe SelfProfile)
lookupSelfProfile = fmap (fmap mk) . wrapClient . Data.lookupAccount
  where
    mk a = SelfProfile (accountUser a)

validateHandle :: Text -> (Handler r) Handle
validateHandle = maybe (throwStd (errorToWai @'InvalidHandle)) return . parseHandle

logEmail :: Email -> (Msg -> Msg)
logEmail email =
  Log.field "email_sha256" (sha256String . cs . show $ email)

logInvitationCode :: InvitationCode -> (Msg -> Msg)
logInvitationCode code = Log.field "invitation_code" (toText $ fromInvitationCode code)

-- | Traverse concurrently and fail on first error.
traverseConcurrentlyWithErrors ::
  (Traversable t, Exception e, MonadUnliftIO m) =>
  (a -> ExceptT e m b) ->
  t a ->
  ExceptT e m (t b)
traverseConcurrentlyWithErrors f =
  ExceptT . try
    . ( traverse (either throwIO pure)
          <=< pooledMapConcurrentlyN 8 (runExceptT . f)
      )

exceptTToMaybe :: Monad m => ExceptT e m () -> m (Maybe e)
exceptTToMaybe = (pure . either Just (const Nothing)) <=< runExceptT

lookupDomainConfig :: MonadReader Env m => Domain -> m (Maybe FederationDomainConfig)
lookupDomainConfig domain = do
  domainConfigs <- fromMaybe [] <$> view (settings . federationDomainConfigs)
  pure $ find ((== domain) . Opts.domain) domainConfigs

-- | If domain is not configured fall back to `FullSearch`
lookupSearchPolicy :: MonadReader Env m => Domain -> m FederatedUserSearchPolicy
lookupSearchPolicy domain = fromMaybe NoSearch <$> (Opts.cfgSearchPolicy <$$> lookupDomainConfig domain)
