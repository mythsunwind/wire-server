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

-- TODO: Move to Brig.User.Account
module Brig.API.User
  ( -- * User Accounts / Profiles
    createUser,
    createUserInviteViaScim,
    checkRestrictedUserCreation,
    Brig.API.User.updateUser,
    changeLocale,
    changeSelfEmail,
    changeEmail,
    changePhone,
    changeHandle,
    CheckHandleResp (..),
    checkHandle,
    lookupHandle,
    changeManagedBy,
    changeAccountStatus,
    suspendAccount,
    Data.lookupAccounts,
    Data.lookupAccount,
    Data.lookupStatus,
    lookupAccountsByIdentity,
    lookupProfile,
    lookupProfiles,
    lookupLocalProfiles,
    getLegalHoldStatus,
    Data.lookupName,
    Data.lookupLocale,
    Data.lookupUser,
    Data.lookupRichInfo,
    Data.lookupRichInfoMultiUsers,
    removeEmail,
    removePhone,
    revokeIdentity,
    deleteUserNoVerify,
    deleteUsersNoVerify,
    Brig.API.User.deleteUser,
    verifyDeleteUser,
    deleteAccount,
    checkHandles,
    isBlacklistedHandle,
    Data.reauthenticate,
    AllowSCIMUpdates (..),

    -- * Activation
    sendActivationCode,
    preverify,
    activate,
    Brig.API.User.lookupActivationCode,
    Data.isActivated,

    -- * Password Management
    changePassword,
    beginPasswordReset,
    completePasswordReset,
    lookupPasswordResetCode,
    Data.lookupPassword,

    -- * Blacklisting
    isBlacklisted,
    blacklistDelete,
    blacklistInsert,

    -- * Phone Prefix blocking
    phonePrefixGet,
    phonePrefixDelete,
    phonePrefixInsert,

    -- * Utilities
    fetchUserIdentity,
  )
where

import Bilge.IO (MonadHttp)
import Bilge.RPC (HasRequestId)
import qualified Brig.API.Error as Error
import qualified Brig.API.Handler as API (Handler, UserNotAllowedToJoinTeam (..))
import Brig.API.Types
import Brig.API.Util
import Brig.App
import qualified Brig.Code as Code
import Brig.Data.Activation (ActivationEvent (..), activationErrorToRegisterError)
import qualified Brig.Data.Activation as Data
import qualified Brig.Data.Blacklist as Blacklist
import qualified Brig.Data.Client as Data
import qualified Brig.Data.Connection as Data
import qualified Brig.Data.PasswordReset as Data
import qualified Brig.Data.Properties as Data
import Brig.Data.User
import qualified Brig.Data.User as Data
import Brig.Data.UserKey
import qualified Brig.Data.UserKey as Data
import Brig.Data.UserPendingActivation
import qualified Brig.Data.UserPendingActivation as Data
import qualified Brig.Federation.Client as Federation
import qualified Brig.IO.Intra as Intra
import qualified Brig.InternalEvent.Types as Internal
import Brig.Options hiding (Timeout, internalEvents)
import Brig.Password
import qualified Brig.Queue as Queue
import qualified Brig.Team.DB as Team
import Brig.Types
import Brig.Types.Code (Timeout (..))
import Brig.Types.Intra
import Brig.Types.Team.Invitation (inCreatedAt, inCreatedBy)
import qualified Brig.Types.Team.Invitation as Team
import Brig.Types.User.Event
import Brig.User.Auth.Cookie (revokeAllCookies)
import Brig.User.Email
import Brig.User.Handle
import Brig.User.Handle.Blacklist
import Brig.User.Phone
import Brig.User.Search.Index (MonadIndexIO)
import qualified Brig.User.Search.TeamSize as TeamSize
import Cassandra
import Control.Arrow ((&&&))
import Control.Error
import Control.Lens (view, (^.))
import Control.Monad.Catch
import Data.ByteString.Conversion
import qualified Data.Currency as Currency
import Data.Handle (Handle)
import Data.Id as Id
import Data.Json.Util
import Data.LegalHold (UserLegalHoldStatus (..), defUserLegalHoldStatus)
import Data.List1 (List1)
import qualified Data.Map.Strict as Map
import qualified Data.Metrics as Metrics
import Data.Misc (PlainTextPassword (..))
import Data.Qualified
import Data.Time.Clock (addUTCTime, diffUTCTime)
import Data.UUID.V4 (nextRandom)
import qualified Galley.Types.Teams as Team
import qualified Galley.Types.Teams.Intra as Team
import Imports
import Network.Wai.Utilities
import System.Logger.Class (MonadLogger)
import qualified System.Logger.Class as Log
import System.Logger.Message
import UnliftIO.Async
import Wire.API.Error
import qualified Wire.API.Error.Brig as E
import Wire.API.Federation.Error
import Wire.API.Routes.Internal.Brig.Connection
import Wire.API.Team.Member (legalHoldStatus)
import Wire.API.User

data AllowSCIMUpdates
  = AllowSCIMUpdates
  | ForbidSCIMUpdates
  deriving (Show, Eq, Ord)

-------------------------------------------------------------------------------
-- Create User

data IdentityError
  = IdentityErrorBlacklistedEmail
  | IdentityErrorBlacklistedPhone
  | IdentityErrorUserKeyExists

identityErrorToRegisterError :: IdentityError -> RegisterError
identityErrorToRegisterError = \case
  IdentityErrorBlacklistedEmail -> RegisterErrorBlacklistedEmail
  IdentityErrorBlacklistedPhone -> RegisterErrorBlacklistedPhone
  IdentityErrorUserKeyExists -> RegisterErrorUserKeyExists

identityErrorToBrigError :: IdentityError -> Error.Error
identityErrorToBrigError = \case
  IdentityErrorBlacklistedEmail -> Error.StdError $ errorToWai @'E.BlacklistedEmail
  IdentityErrorBlacklistedPhone -> Error.StdError $ errorToWai @'E.BlacklistedPhone
  IdentityErrorUserKeyExists -> Error.StdError $ errorToWai @'E.UserKeyExists

verifyUniquenessAndCheckBlacklist :: UserKey -> ExceptT IdentityError (AppT r) ()
verifyUniquenessAndCheckBlacklist uk = do
  wrapClientE $ checkKey Nothing uk
  blacklisted <- lift $ wrapClient $ Blacklist.exists uk
  when blacklisted $
    throwE (foldKey (const IdentityErrorBlacklistedEmail) (const IdentityErrorBlacklistedPhone) uk)
  where
    checkKey u k = do
      av <- lift $ Data.keyAvailable k u
      unless av $
        throwE IdentityErrorUserKeyExists

-- docs/reference/user/registration.md {#RefRegistration}
createUser :: NewUser -> ExceptT RegisterError (AppT r) CreateUserResult
createUser new = do
  (email, phone) <- validateEmailAndPhone new

  -- get invitation and existing account
  (newTeam, teamInvitation, tid) <-
    case newUserTeam new of
      Just (NewTeamMember i) -> do
        mbTeamInv <- findTeamInvitation (userEmailKey <$> email) i
        case mbTeamInv of
          Just (inv, info, tid) ->
            pure (Nothing, Just (inv, info), Just tid)
          Nothing ->
            pure (Nothing, Nothing, Nothing)
      Just (NewTeamCreator t) -> do
        (Just t,Nothing,) <$> (Just . Id <$> liftIO nextRandom)
      Just (NewTeamMemberSSO tid) ->
        pure (Nothing, Nothing, Just tid)
      Nothing ->
        pure (Nothing, Nothing, Nothing)
  let mbInv = Team.inInvitation . fst <$> teamInvitation
  mbExistingAccount <- lift $ join <$> for mbInv (\(Id uuid) -> wrapClient $ Data.lookupAccount (Id uuid))

  let (new', mbHandle) = case mbExistingAccount of
        Nothing ->
          ( new {newUserIdentity = newIdentity email phone (newUserSSOId new)},
            Nothing
          )
        Just existingAccount ->
          let existingUser = accountUser existingAccount
              mbSSOid =
                case (teamInvitation, email, userManagedBy existingUser) of
                  -- isJust teamInvitation And ManagedByScim implies that the
                  -- user invitation has been generated by SCIM and there is no IdP
                  (Just _, Just em, ManagedByScim) ->
                    Just $ UserScimExternalId (fromEmail em)
                  _ -> newUserSSOId new
           in ( new
                  { newUserManagedBy = Just (userManagedBy existingUser),
                    newUserIdentity = newIdentity email phone mbSSOid
                  },
                userHandle existingUser
              )

  -- Create account
  account <- lift $ do
    (account, pw) <- wrapClient $ newAccount new' mbInv tid mbHandle

    let uid = userId (accountUser account)
    Log.debug $ field "user" (toByteString uid) . field "action" (Log.val "User.createUser")
    Log.info $ field "user" (toByteString uid) . msg (val "Creating user")

    wrapClient $ Data.insertAccount account Nothing pw False
    wrapHttp $ Intra.createSelfConv uid
    wrapHttpClient $ Intra.onUserEvent uid Nothing (UserCreated (accountUser account))

    pure account

  let uid = userId (accountUser account)

  createUserTeam <- do
    activatedTeam <- lift $ do
      case (tid, newTeam) of
        (Just tid', Just nt) -> do
          created <- wrapHttp $ Intra.createTeam uid (bnuTeam nt) tid'
          let activating = isJust (newUserEmailCode new)
          pure $
            if activating
              then Just created
              else Nothing
        _ -> pure Nothing

    joinedTeamInvite <- case teamInvitation of
      Just (inv, invInfo) -> do
        let em = Team.inInviteeEmail inv
        acceptTeamInvitation account inv invInfo (userEmailKey em) (EmailIdentity em)
        Team.TeamName nm <- lift $ wrapHttp $ Intra.getTeamName (Team.inTeam inv)
        pure (Just $ CreateUserTeam (Team.inTeam inv) nm)
      Nothing -> pure Nothing

    joinedTeamSSO <- case (newUserIdentity new', tid) of
      (Just ident@(SSOIdentity (UserSSOId _) _ _), Just tid') -> Just <$> addUserToTeamSSO account tid' ident
      _ -> pure Nothing

    pure (activatedTeam <|> joinedTeamInvite <|> joinedTeamSSO)

  edata <-
    if isJust teamInvitation
      then pure Nothing
      else handleEmailActivation email uid newTeam

  pdata <- handlePhoneActivation phone uid

  lift $ initAccountFeatureConfig uid

  return $! CreateUserResult account edata pdata createUserTeam
  where
    -- NOTE: all functions in the where block don't use any arguments of createUser

    validateEmailAndPhone :: NewUser -> ExceptT RegisterError (AppT r) (Maybe Email, Maybe Phone)
    validateEmailAndPhone newUser = do
      -- Validate e-mail
      email <- for (newUserEmail newUser) $ \e ->
        either
          (const $ throwE RegisterErrorInvalidEmail)
          return
          (validateEmail e)

      -- Validate phone
      phone <- for (newUserPhone newUser) $ \p ->
        maybe
          (throwE RegisterErrorInvalidPhone)
          return
          =<< lift (wrapClient $ validatePhone p)

      for_ (catMaybes [userEmailKey <$> email, userPhoneKey <$> phone]) $ \k ->
        verifyUniquenessAndCheckBlacklist k !>> identityErrorToRegisterError

      pure (email, phone)

    findTeamInvitation :: Maybe UserKey -> InvitationCode -> ExceptT RegisterError (AppT r) (Maybe (Team.Invitation, Team.InvitationInfo, TeamId))
    findTeamInvitation Nothing _ = throwE RegisterErrorMissingIdentity
    findTeamInvitation (Just e) c =
      lift (wrapClient $ Team.lookupInvitationInfo c) >>= \case
        Just ii -> do
          inv <- lift . wrapClient $ Team.lookupInvitation (Team.iiTeam ii) (Team.iiInvId ii)
          case (inv, Team.inInviteeEmail <$> inv) of
            (Just invite, Just em)
              | e == userEmailKey em -> do
                _ <- ensureMemberCanJoin (Team.iiTeam ii)
                return $ Just (invite, ii, Team.iiTeam ii)
            _ -> throwE RegisterErrorInvalidInvitationCode
        Nothing -> throwE RegisterErrorInvalidInvitationCode

    ensureMemberCanJoin :: TeamId -> ExceptT RegisterError (AppT r) ()
    ensureMemberCanJoin tid = do
      maxSize <- fromIntegral . setMaxTeamSize <$> view settings
      (TeamSize teamSize) <- TeamSize.teamSize tid
      when (teamSize >= maxSize) $
        throwE RegisterErrorTooManyTeamMembers
      -- FUTUREWORK: The above can easily be done/tested in the intra call.
      --             Remove after the next release.
      canAdd <- lift $ wrapHttp $ Intra.checkUserCanJoinTeam tid
      case canAdd of
        Just e -> throwM $ API.UserNotAllowedToJoinTeam e
        Nothing -> pure ()

    acceptTeamInvitation ::
      UserAccount ->
      Team.Invitation ->
      Team.InvitationInfo ->
      UserKey ->
      UserIdentity ->
      ExceptT RegisterError (AppT r) ()
    acceptTeamInvitation account inv ii uk ident = do
      let uid = userId (accountUser account)
      ok <- lift . wrapClient $ Data.claimKey uk uid
      unless ok $
        throwE RegisterErrorUserKeyExists
      let minvmeta :: (Maybe (UserId, UTCTimeMillis), Team.Role)
          minvmeta = ((,inCreatedAt inv) <$> inCreatedBy inv, Team.inRole inv)
      added <- lift $ wrapHttp $ Intra.addTeamMember uid (Team.iiTeam ii) minvmeta
      unless added $
        throwE RegisterErrorTooManyTeamMembers
      lift $ do
        wrapClient $ activateUser uid ident -- ('insertAccount' sets column activated to False; here it is set to True.)
        void $ onActivated (AccountActivated account)
        Log.info $
          field "user" (toByteString uid)
            . field "team" (toByteString $ Team.iiTeam ii)
            . msg (val "Accepting invitation")
        wrapClient $ do
          Data.usersPendingActivationRemove uid
          Team.deleteInvitation (Team.inTeam inv) (Team.inInvitation inv)

    addUserToTeamSSO :: UserAccount -> TeamId -> UserIdentity -> ExceptT RegisterError (AppT r) CreateUserTeam
    addUserToTeamSSO account tid ident = do
      let uid = userId (accountUser account)
      added <- lift $ wrapHttp $ Intra.addTeamMember uid tid (Nothing, Team.defaultRole)
      unless added $
        throwE RegisterErrorTooManyTeamMembers
      lift $ do
        wrapClient $ activateUser uid ident
        void $ onActivated (AccountActivated account)
        Log.info $
          field "user" (toByteString uid)
            . field "team" (toByteString tid)
            . msg (val "Added via SSO")
      Team.TeamName nm <- lift $ wrapHttp $ Intra.getTeamName tid
      pure $ CreateUserTeam tid nm

    -- Handle e-mail activation (deprecated, see #RefRegistrationNoPreverification in /docs/reference/user/registration.md)
    handleEmailActivation :: Maybe Email -> UserId -> Maybe BindingNewTeamUser -> ExceptT RegisterError (AppT r) (Maybe Activation)
    handleEmailActivation email uid newTeam = do
      fmap join . for (userEmailKey <$> email) $ \ek -> case newUserEmailCode new of
        Nothing -> do
          timeout <- setActivationTimeout <$> view settings
          edata <- lift . wrapClient $ Data.newActivation ek timeout (Just uid)
          lift . Log.info $
            field "user" (toByteString uid)
              . field "activation.key" (toByteString $ activationKey edata)
              . msg (val "Created email activation key/code pair")
          return $ Just edata
        Just c -> do
          ak <- liftIO $ Data.mkActivationKey ek
          void $
            activateWithCurrency (ActivateKey ak) c (Just uid) (bnuCurrency =<< newTeam)
              !>> activationErrorToRegisterError
          return Nothing

    -- Handle phone activation (deprecated, see #RefRegistrationNoPreverification in /docs/reference/user/registration.md)
    handlePhoneActivation :: Maybe Phone -> UserId -> ExceptT RegisterError (AppT r) (Maybe Activation)
    handlePhoneActivation phone uid = do
      fmap join . for (userPhoneKey <$> phone) $ \pk -> case newUserPhoneCode new of
        Nothing -> do
          timeout <- setActivationTimeout <$> view settings
          pdata <- lift . wrapClient $ Data.newActivation pk timeout (Just uid)
          lift . Log.info $
            field "user" (toByteString uid)
              . field "activation.key" (toByteString $ activationKey pdata)
              . msg (val "Created phone activation key/code pair")
          return $ Just pdata
        Just c -> do
          ak <- liftIO $ Data.mkActivationKey pk
          void $ activate (ActivateKey ak) c (Just uid) !>> activationErrorToRegisterError
          return Nothing

initAccountFeatureConfig :: UserId -> (AppT r) ()
initAccountFeatureConfig uid = do
  mbCciDefNew <- view (settings . getAfcConferenceCallingDefNewMaybe)
  forM_ mbCciDefNew $ wrapClient . Data.updateFeatureConferenceCalling uid . Just

-- | 'createUser' is becoming hard to maintian, and instead of adding more case distinctions
-- all over the place there, we add a new function that handles just the one new flow where
-- users are invited to the team via scim.
createUserInviteViaScim :: UserId -> NewUserScimInvitation -> ExceptT Error.Error (AppT r) UserAccount
createUserInviteViaScim uid (NewUserScimInvitation tid loc name rawEmail) = do
  email <- either (const . throwE . Error.StdError $ errorToWai @'E.InvalidEmail) pure (validateEmail rawEmail)
  let emKey = userEmailKey email
  verifyUniquenessAndCheckBlacklist emKey !>> identityErrorToBrigError
  account <- lift . wrapClient $ newAccountInviteViaScim uid tid loc name email
  lift . Log.debug $ field "user" (toByteString . userId . accountUser $ account) . field "action" (Log.val "User.createUserInviteViaScim")

  -- add the expiry table entry first!  (if brig creates an account, and then crashes before
  -- creating the expiry table entry, gc will miss user data.)
  expiresAt <- do
    ttl <- setTeamInvitationTimeout <$> view settings
    now <- liftIO =<< view currentTime
    pure $ addUTCTime (realToFrac ttl) now
  lift . wrapClient $ Data.usersPendingActivationAdd (UserPendingActivation uid expiresAt)

  let activated =
        -- treating 'PendingActivation' as 'Active', but then 'Brig.Data.User.toIdentity'
        -- would not produce an identity, and so we won't have the email address to construct
        -- the SCIM user.
        True
  lift . wrapClient $ Data.insertAccount account Nothing Nothing activated

  return account

-- | docs/reference/user/registration.md {#RefRestrictRegistration}.
checkRestrictedUserCreation :: NewUser -> ExceptT RegisterError (AppT r) ()
checkRestrictedUserCreation new = do
  restrictPlease <- lift . asks $ fromMaybe False . setRestrictUserCreation . view settings
  when
    ( restrictPlease
        && not (isNewUserTeamMember new)
        && not (isNewUserEphemeral new)
    )
    $ throwE RegisterErrorUserCreationRestricted

-------------------------------------------------------------------------------
-- Update Profile

updateUser :: UserId -> Maybe ConnId -> UserUpdate -> AllowSCIMUpdates -> ExceptT UpdateProfileError (AppT r) ()
updateUser uid mconn uu allowScim = do
  for_ (uupName uu) $ \newName -> do
    mbUser <- lift . wrapClient $ Data.lookupUser WithPendingInvitations uid
    user <- maybe (throwE ProfileNotFound) pure mbUser
    unless
      ( userManagedBy user /= ManagedByScim
          || userDisplayName user == newName
          || allowScim == AllowSCIMUpdates
      )
      $ throwE DisplayNameManagedByScim
  lift $ do
    wrapClient $ Data.updateUser uid uu
    wrapHttpClient $ Intra.onUserEvent uid mconn (profileUpdated uid uu)

-------------------------------------------------------------------------------
-- Update Locale

changeLocale :: UserId -> ConnId -> LocaleUpdate -> (AppT r) ()
changeLocale uid conn (LocaleUpdate loc) = do
  wrapClient $ Data.updateLocale uid loc
  wrapHttpClient $ Intra.onUserEvent uid (Just conn) (localeUpdate uid loc)

-------------------------------------------------------------------------------
-- Update ManagedBy

changeManagedBy :: UserId -> ConnId -> ManagedByUpdate -> (AppT r) ()
changeManagedBy uid conn (ManagedByUpdate mb) = do
  wrapClient $ Data.updateManagedBy uid mb
  wrapHttpClient $ Intra.onUserEvent uid (Just conn) (managedByUpdate uid mb)

--------------------------------------------------------------------------------
-- Change Handle

changeHandle :: UserId -> Maybe ConnId -> Handle -> AllowSCIMUpdates -> ExceptT ChangeHandleError (AppT r) ()
changeHandle uid mconn hdl allowScim = do
  when (isBlacklistedHandle hdl) $
    throwE ChangeHandleInvalid
  usr <- lift $ wrapClient $ Data.lookupUser WithPendingInvitations uid
  case usr of
    Nothing -> throwE ChangeHandleNoIdentity
    Just u -> do
      unless
        ( userManagedBy u /= ManagedByScim
            || Just hdl == userHandle u
            || allowScim == AllowSCIMUpdates
        )
        $ throwE ChangeHandleManagedByScim
      claim u
  where
    claim u = do
      unless (isJust (userIdentity u)) $
        throwE ChangeHandleNoIdentity
      claimed <- lift . wrapClient $ claimHandle (userId u) (userHandle u) hdl
      unless claimed $
        throwE ChangeHandleExists
      lift $ wrapHttpClient $ Intra.onUserEvent uid mconn (handleUpdated uid hdl)

--------------------------------------------------------------------------------
-- Check Handle

data CheckHandleResp
  = CheckHandleInvalid
  | CheckHandleFound
  | CheckHandleNotFound

checkHandle :: Text -> API.Handler r CheckHandleResp
checkHandle uhandle = do
  xhandle <- validateHandle uhandle
  owner <- lift . wrapClient $ lookupHandle xhandle
  if
      | isJust owner ->
        -- Handle is taken (=> getHandleInfo will return 200)
        return CheckHandleFound
      | isBlacklistedHandle xhandle ->
        -- Handle is free but cannot be taken
        --
        -- FUTUREWORK: i wonder if this is correct?  isn't this the error for malformed
        -- handles?  shouldn't we throw not-found here?  or should there be a fourth case
        -- 'CheckHandleBlacklisted'?
        return CheckHandleInvalid
      | otherwise ->
        -- Handle is free and can be taken
        return CheckHandleNotFound

--------------------------------------------------------------------------------
-- Check Handles

checkHandles :: MonadClient m => [Handle] -> Word -> m [Handle]
checkHandles check num = reverse <$> collectFree [] check num
  where
    collectFree free _ 0 = return free
    collectFree free [] _ = return free
    collectFree free (h : hs) n =
      if isBlacklistedHandle h
        then collectFree free hs n
        else do
          owner <- glimpseHandle h
          case owner of
            Nothing -> collectFree (h : free) hs (n - 1)
            Just _ -> collectFree free hs n

-------------------------------------------------------------------------------
-- Change Email

-- | Call 'changeEmail' and process result: if email changes to itself, succeed, if not, send
-- validation email.
changeSelfEmail :: UserId -> Email -> AllowSCIMUpdates -> ExceptT Error.Error (AppT r) ChangeEmailResponse
changeSelfEmail u email allowScim = do
  changeEmail u email allowScim !>> Error.changeEmailError >>= \case
    ChangeEmailIdempotent ->
      pure ChangeEmailResponseIdempotent
    ChangeEmailNeedsActivation (usr, adata, en) -> do
      lift $ sendOutEmail usr adata en
      pure ChangeEmailResponseNeedsActivation
  where
    sendOutEmail usr adata en = do
      sendActivationMail
        en
        (userDisplayName usr)
        (activationKey adata, activationCode adata)
        (Just (userLocale usr))
        (userIdentity usr)

-- | Prepare changing the email (checking a number of invariants).
changeEmail :: UserId -> Email -> AllowSCIMUpdates -> ExceptT ChangeEmailError (AppT r) ChangeEmailResult
changeEmail u email allowScim = do
  em <-
    either
      (throwE . InvalidNewEmail email)
      return
      (validateEmail email)
  let ek = userEmailKey em
  blacklisted <- lift . wrapClient $ Blacklist.exists ek
  when blacklisted $
    throwE (ChangeBlacklistedEmail email)
  available <- lift . wrapClient $ Data.keyAvailable ek (Just u)
  unless available $
    throwE $
      EmailExists email
  usr <- maybe (throwM $ UserProfileNotFound u) return =<< lift (wrapClient $ Data.lookupUser WithPendingInvitations u)
  case emailIdentity =<< userIdentity usr of
    -- The user already has an email address and the new one is exactly the same
    Just current | current == em -> return ChangeEmailIdempotent
    _ -> do
      unless
        ( userManagedBy usr /= ManagedByScim
            || allowScim == AllowSCIMUpdates
        )
        $ throwE EmailManagedByScim
      timeout <- setActivationTimeout <$> view settings
      act <- lift . wrapClient $ Data.newActivation ek timeout (Just u)
      return $ ChangeEmailNeedsActivation (usr, act, em)

-------------------------------------------------------------------------------
-- Change Phone

changePhone :: UserId -> Phone -> ExceptT ChangePhoneError (AppT r) (Activation, Phone)
changePhone u phone = do
  canonical <-
    maybe
      (throwE InvalidNewPhone)
      return
      =<< lift (wrapClient $ validatePhone phone)
  let pk = userPhoneKey canonical
  available <- lift . wrapClient $ Data.keyAvailable pk (Just u)
  unless available $
    throwE PhoneExists
  timeout <- setActivationTimeout <$> view settings
  blacklisted <- lift . wrapClient $ Blacklist.exists pk
  when blacklisted $
    throwE BlacklistedNewPhone
  -- check if any prefixes of this phone number are blocked
  prefixExcluded <- lift . wrapClient $ Blacklist.existsAnyPrefix canonical
  when prefixExcluded $
    throwE BlacklistedNewPhone
  act <- lift . wrapClient $ Data.newActivation pk timeout (Just u)
  return (act, canonical)

-------------------------------------------------------------------------------
-- Remove Email

removeEmail :: UserId -> ConnId -> ExceptT RemoveIdentityError (AppT r) ()
removeEmail uid conn = do
  ident <- lift $ fetchUserIdentity uid
  case ident of
    Just (FullIdentity e _) -> lift $ do
      wrapClient . deleteKey $ userEmailKey e
      wrapClient $ Data.deleteEmail uid
      wrapHttpClient $ Intra.onUserEvent uid (Just conn) (emailRemoved uid e)
    Just _ -> throwE LastIdentity
    Nothing -> throwE NoIdentity

-------------------------------------------------------------------------------
-- Remove Phone

removePhone :: UserId -> ConnId -> ExceptT RemoveIdentityError (AppT r) ()
removePhone uid conn = do
  ident <- lift $ fetchUserIdentity uid
  case ident of
    Just (FullIdentity _ p) -> do
      pw <- lift . wrapClient $ Data.lookupPassword uid
      unless (isJust pw) $
        throwE NoPassword
      lift $ do
        wrapClient . deleteKey $ userPhoneKey p
        wrapClient $ Data.deletePhone uid
        wrapHttpClient $ Intra.onUserEvent uid (Just conn) (phoneRemoved uid p)
    Just _ -> throwE LastIdentity
    Nothing -> throwE NoIdentity

-------------------------------------------------------------------------------
-- Forcefully revoke a verified identity

revokeIdentity :: Either Email Phone -> AppT r ()
revokeIdentity key = do
  let uk = either userEmailKey userPhoneKey key
  mu <- wrapClient $ Data.lookupKey uk
  case mu of
    Nothing -> return ()
    Just u ->
      fetchUserIdentity u >>= \case
        Just (FullIdentity _ _) -> revokeKey u uk
        Just (EmailIdentity e) | Left e == key -> do
          revokeKey u uk
          wrapClient $ Data.deactivateUser u
        Just (PhoneIdentity p) | Right p == key -> do
          revokeKey u uk
          wrapClient $ Data.deactivateUser u
        _ -> return ()
  where
    revokeKey :: UserId -> UserKey -> AppT r ()
    revokeKey u uk = do
      wrapClient $ deleteKey uk
      wrapClient $
        foldKey
          (\(_ :: Email) -> Data.deleteEmail u)
          (\(_ :: Phone) -> Data.deletePhone u)
          uk
      wrapHttpClient $
        Intra.onUserEvent u Nothing $
          foldKey
            (emailRemoved u)
            (phoneRemoved u)
            uk

-------------------------------------------------------------------------------
-- Change Account Status

changeAccountStatus ::
  forall m.
  ( MonadClient m,
    MonadLogger m,
    MonadIndexIO m,
    MonadReader Env m,
    MonadMask m,
    MonadHttp m,
    HasRequestId m,
    MonadUnliftIO m
  ) =>
  List1 UserId ->
  AccountStatus ->
  ExceptT AccountStatusError m ()
changeAccountStatus usrs status = do
  ev <- case status of
    Active -> return UserResumed
    Suspended -> lift $ mapConcurrently revokeAllCookies usrs >> return UserSuspended
    Deleted -> throwE InvalidAccountStatus
    Ephemeral -> throwE InvalidAccountStatus
    PendingInvitation -> throwE InvalidAccountStatus
  lift $ mapConcurrently_ (update ev) usrs
  where
    update ::
      (UserId -> UserEvent) ->
      UserId ->
      m ()
    update ev u = do
      Data.updateStatus u status
      Intra.onUserEvent u Nothing (ev u)

suspendAccount ::
  ( MonadClient m,
    MonadLogger m,
    MonadIndexIO m,
    MonadReader Env m,
    MonadMask m,
    MonadHttp m,
    HasRequestId m,
    MonadUnliftIO m
  ) =>
  HasCallStack =>
  List1 UserId ->
  m ()
suspendAccount usrs =
  runExceptT (changeAccountStatus usrs Suspended) >>= \case
    Right _ -> pure ()
    Left InvalidAccountStatus -> error "impossible."

-------------------------------------------------------------------------------
-- Activation

activate ::
  ActivationTarget ->
  ActivationCode ->
  -- | The user for whom to activate the key.
  Maybe UserId ->
  ExceptT ActivationError (AppT r) ActivationResult
activate tgt code usr = activateWithCurrency tgt code usr Nothing

activateWithCurrency ::
  ActivationTarget ->
  ActivationCode ->
  -- | The user for whom to activate the key.
  Maybe UserId ->
  -- | Potential currency update.
  -- ^ TODO: to be removed once billing supports currency changes after team creation
  Maybe Currency.Alpha ->
  ExceptT ActivationError (AppT r) ActivationResult
activateWithCurrency tgt code usr cur = do
  key <- wrapClientE $ mkActivationKey tgt
  lift . Log.info $
    field "activation.key" (toByteString key)
      . field "activation.code" (toByteString code)
      . msg (val "Activating")
  event <- wrapClientE $ Data.activateKey key code usr
  case event of
    Nothing -> return ActivationPass
    Just e -> do
      (uid, ident, first) <- lift $ onActivated e
      when first $
        lift $
          activateTeam uid
      return $ ActivationSuccess ident first
  where
    activateTeam uid = do
      tid <- wrapHttp $ Intra.getTeamId uid
      for_ tid $ \t -> wrapHttp $ Intra.changeTeamStatus t Team.Active cur

preverify ::
  ( MonadClient m,
    MonadReader Env m
  ) =>
  ActivationTarget ->
  ActivationCode ->
  ExceptT ActivationError m ()
preverify tgt code = do
  key <- mkActivationKey tgt
  void $ Data.verifyCode key code

onActivated :: ActivationEvent -> (AppT r) (UserId, Maybe UserIdentity, Bool)
onActivated (AccountActivated account) = do
  let uid = userId (accountUser account)
  Log.debug $ field "user" (toByteString uid) . field "action" (Log.val "User.onActivated")
  Log.info $ field "user" (toByteString uid) . msg (val "User activated")
  wrapHttpClient $ Intra.onUserEvent uid Nothing $ UserActivated (accountUser account)
  return (uid, userIdentity (accountUser account), True)
onActivated (EmailActivated uid email) = do
  wrapHttpClient $ Intra.onUserEvent uid Nothing (emailUpdated uid email)
  return (uid, Just (EmailIdentity email), False)
onActivated (PhoneActivated uid phone) = do
  wrapHttpClient $ Intra.onUserEvent uid Nothing (phoneUpdated uid phone)
  return (uid, Just (PhoneIdentity phone), False)

-- docs/reference/user/activation.md {#RefActivationRequest}
sendActivationCode :: Either Email Phone -> Maybe Locale -> Bool -> ExceptT SendActivationCodeError (AppT r) ()
sendActivationCode emailOrPhone loc call = case emailOrPhone of
  Left email -> do
    ek <-
      either
        (const . throwE . InvalidRecipient $ userEmailKey email)
        (return . userEmailKey)
        (validateEmail email)
    exists <- lift $ isJust <$> wrapClient (Data.lookupKey ek)
    when exists $
      throwE $
        UserKeyInUse ek
    blacklisted <- lift . wrapClient $ Blacklist.exists ek
    when blacklisted $
      throwE (ActivationBlacklistedUserKey ek)
    uc <- lift . wrapClient $ Data.lookupActivationCode ek
    case uc of
      Nothing -> sendVerificationEmail ek Nothing -- Fresh code request, no user
      Just (Nothing, c) -> sendVerificationEmail ek (Just c) -- Re-requesting existing code
      Just (Just uid, c) -> sendActivationEmail ek c uid -- User re-requesting activation
  Right phone -> do
    -- validatePhone returns the canonical E.164 phone number format
    canonical <-
      maybe
        (throwE $ InvalidRecipient (userPhoneKey phone))
        return
        =<< lift (wrapClient $ validatePhone phone)
    let pk = userPhoneKey canonical
    exists <- lift $ isJust <$> wrapClient (Data.lookupKey pk)
    when exists $
      throwE $
        UserKeyInUse pk
    blacklisted <- lift . wrapClient $ Blacklist.exists pk
    when blacklisted $
      throwE (ActivationBlacklistedUserKey pk)
    -- check if any prefixes of this phone number are blocked
    prefixExcluded <- lift . wrapClient $ Blacklist.existsAnyPrefix canonical
    when prefixExcluded $
      throwE (ActivationBlacklistedUserKey pk)
    c <- lift . wrapClient $ fmap snd <$> Data.lookupActivationCode pk
    p <- wrapClientE $ mkPair pk c Nothing
    void . forPhoneKey pk $ \ph ->
      lift $
        if call
          then wrapClient $ sendActivationCall ph p loc
          else wrapClient $ sendActivationSms ph p loc
  where
    notFound = throwM . UserDisplayNameNotFound
    mkPair k c u = do
      timeout <- setActivationTimeout <$> view settings
      case c of
        Just c' -> liftIO $ (,c') <$> Data.mkActivationKey k
        Nothing -> lift $ do
          dat <- Data.newActivation k timeout u
          return (activationKey dat, activationCode dat)
    sendVerificationEmail ek uc = do
      p <- wrapClientE $ mkPair ek uc Nothing
      void . forEmailKey ek $ \em ->
        lift $
          sendVerificationMail em p loc
    sendActivationEmail ek uc uid = do
      -- FUTUREWORK(fisx): we allow for 'PendingInvitations' here, but I'm not sure this
      -- top-level function isn't another piece of a deprecated onboarding flow?
      u <- maybe (notFound uid) return =<< lift (wrapClient $ Data.lookupUser WithPendingInvitations uid)
      p <- wrapClientE $ mkPair ek (Just uc) (Just uid)
      let ident = userIdentity u
          name = userDisplayName u
          loc' = loc <|> Just (userLocale u)
      void . forEmailKey ek $ \em -> lift $ do
        -- Get user's team, if any.
        mbTeam <- mapM (fmap Team.tdTeam . wrapHttp . Intra.getTeam) (userTeam u)
        -- Depending on whether the user is a team creator, send either
        -- a team activation email or a regular email. Note that we
        -- don't have to check if the team is binding because if the
        -- user has 'userTeam' set, it must be binding.
        case mbTeam of
          Just team
            | team ^. Team.teamCreator == uid ->
              sendTeamActivationMail em name p loc' (team ^. Team.teamName)
          _otherwise ->
            sendActivationMail em name p loc' ident

mkActivationKey :: (MonadClient m, MonadReader Env m) => ActivationTarget -> ExceptT ActivationError m ActivationKey
mkActivationKey (ActivateKey k) = return k
mkActivationKey (ActivateEmail e) = do
  ek <-
    either
      (throwE . InvalidActivationEmail e)
      (return . userEmailKey)
      (validateEmail e)
  liftIO $ Data.mkActivationKey ek
mkActivationKey (ActivatePhone p) = do
  pk <-
    maybe
      (throwE $ InvalidActivationPhone p)
      (return . userPhoneKey)
      =<< lift (validatePhone p)
  liftIO $ Data.mkActivationKey pk

-------------------------------------------------------------------------------
-- Password Management

changePassword :: UserId -> PasswordChange -> ExceptT ChangePasswordError (AppT r) ()
changePassword uid cp = do
  activated <- lift . wrapClient $ Data.isActivated uid
  unless activated $
    throwE ChangePasswordNoIdentity
  currpw <- lift . wrapClient $ Data.lookupPassword uid
  let newpw = cpNewPassword cp
  case (currpw, cpOldPassword cp) of
    (Nothing, _) -> lift . wrapClient $ Data.updatePassword uid newpw
    (Just _, Nothing) -> throwE InvalidCurrentPassword
    (Just pw, Just pw') -> do
      unless (verifyPassword pw' pw) $
        throwE InvalidCurrentPassword
      when (verifyPassword newpw pw) $
        throwE ChangePasswordMustDiffer
      lift $ wrapClient (Data.updatePassword uid newpw) >> wrapClient (revokeAllCookies uid)

beginPasswordReset :: Either Email Phone -> ExceptT PasswordResetError (AppT r) (UserId, PasswordResetPair)
beginPasswordReset target = do
  let key = either userEmailKey userPhoneKey target
  user <- lift (wrapClient $ Data.lookupKey key) >>= maybe (throwE InvalidPasswordResetKey) return
  lift . Log.debug $ field "user" (toByteString user) . field "action" (Log.val "User.beginPasswordReset")
  status <- lift . wrapClient $ Data.lookupStatus user
  unless (status == Just Active) $
    throwE InvalidPasswordResetKey
  code <- lift . wrapClient $ Data.lookupPasswordResetCode user
  when (isJust code) $
    throwE (PasswordResetInProgress Nothing)
  (user,) <$> lift (wrapClient $ Data.createPasswordResetCode user target)

completePasswordReset :: PasswordResetIdentity -> PasswordResetCode -> PlainTextPassword -> ExceptT PasswordResetError (AppT r) ()
completePasswordReset ident code pw = do
  key <- mkPasswordResetKey ident
  muid :: Maybe UserId <- lift . wrapClient $ Data.verifyPasswordResetCode (key, code)
  case muid of
    Nothing -> throwE InvalidPasswordResetCode
    Just uid -> do
      lift . Log.debug $ field "user" (toByteString uid) . field "action" (Log.val "User.completePasswordReset")
      checkNewIsDifferent uid pw
      lift . wrapClient $ do
        Data.updatePassword uid pw
        Data.deletePasswordResetCode key
        revokeAllCookies uid

-- | Pull the current password of a user and compare it against the one about to be installed.
-- If the two are the same, throw an error.  If no current password can be found, do nothing.
checkNewIsDifferent :: UserId -> PlainTextPassword -> ExceptT PasswordResetError (AppT r) ()
checkNewIsDifferent uid pw = do
  mcurrpw <- lift . wrapClient $ Data.lookupPassword uid
  case mcurrpw of
    Just currpw | verifyPassword pw currpw -> throwE ResetPasswordMustDiffer
    _ -> pure ()

mkPasswordResetKey :: PasswordResetIdentity -> ExceptT PasswordResetError (AppT r) PasswordResetKey
mkPasswordResetKey ident = case ident of
  PasswordResetIdentityKey k -> return k
  PasswordResetEmailIdentity e -> wrapClientE (user (userEmailKey e)) >>= liftIO . Data.mkPasswordResetKey
  PasswordResetPhoneIdentity p -> wrapClientE (user (userPhoneKey p)) >>= liftIO . Data.mkPasswordResetKey
  where
    user uk = lift (Data.lookupKey uk) >>= maybe (throwE InvalidPasswordResetKey) return

-------------------------------------------------------------------------------
-- User Deletion

-- | Initiate validation of a user's delete request.  Called via @delete /self@.  Users with an
-- 'UserSSOId' can still do this if they also have an 'Email', 'Phone', and/or password.  Otherwise,
-- the team admin has to delete them via the team console on galley.
--
-- Owners are not allowed to delete themselves.  Instead, they must ask a fellow owner to
-- delete them in the team settings.  This protects teams against orphanhood.
--
-- TODO: communicate deletions of SSO users to SSO service.
deleteUser :: UserId -> Maybe PlainTextPassword -> ExceptT DeleteUserError (AppT r) (Maybe Timeout)
deleteUser uid pwd = do
  account <- lift . wrapClient $ Data.lookupAccount uid
  case account of
    Nothing -> throwE DeleteUserInvalid
    Just a -> case accountStatus a of
      Deleted -> return Nothing
      Suspended -> ensureNotOwner a >> go a
      Active -> ensureNotOwner a >> go a
      Ephemeral -> go a
      PendingInvitation -> go a
  where
    ensureNotOwner :: UserAccount -> ExceptT DeleteUserError (AppT r) ()
    ensureNotOwner acc = do
      case userTeam $ accountUser acc of
        Nothing -> pure ()
        Just tid -> do
          isOwner <- lift $ wrapHttp $ Intra.memberIsTeamOwner tid uid
          when isOwner $ throwE DeleteUserOwnerDeletingSelf
    go a = maybe (byIdentity a) (byPassword a) pwd
    getEmailOrPhone :: UserIdentity -> Maybe (Either Email Phone)
    getEmailOrPhone (FullIdentity e _) = Just $ Left e
    getEmailOrPhone (EmailIdentity e) = Just $ Left e
    getEmailOrPhone (SSOIdentity _ (Just e) _) = Just $ Left e
    getEmailOrPhone (PhoneIdentity p) = Just $ Right p
    getEmailOrPhone (SSOIdentity _ _ (Just p)) = Just $ Right p
    getEmailOrPhone (SSOIdentity _ Nothing Nothing) = Nothing
    byIdentity a = case getEmailOrPhone =<< userIdentity (accountUser a) of
      Just emailOrPhone -> sendCode a emailOrPhone
      Nothing -> case pwd of
        Just _ -> throwE DeleteUserMissingPassword
        Nothing -> lift $ wrapHttpClient $ deleteAccount a >> return Nothing
    byPassword a pw = do
      lift . Log.info $
        field "user" (toByteString uid)
          . msg (val "Attempting account deletion with a password")
      actual <- lift . wrapClient $ Data.lookupPassword uid
      case actual of
        Nothing -> throwE DeleteUserInvalidPassword
        Just p -> do
          unless (verifyPassword pw p) $
            throwE DeleteUserInvalidPassword
          lift $ wrapHttpClient $ deleteAccount a >> return Nothing
    sendCode a target = do
      gen <- Code.mkGen (either Code.ForEmail Code.ForPhone target)
      pending <- lift . wrapClient $ Code.lookup (Code.genKey gen) Code.AccountDeletion
      case pending of
        Just c -> throwE $! DeleteUserPendingCode (Code.codeTTL c)
        Nothing -> do
          lift . Log.info $
            field "user" (toByteString uid)
              . msg (val "Sending verification code for account deletion")
          c <-
            Code.generate
              gen
              Code.AccountDeletion
              (Code.Retries 3)
              (Code.Timeout 600)
              (Just (toUUID uid))
          wrapClientE $ Code.insert c
          let k = Code.codeKey c
          let v = Code.codeValue c
          let l = userLocale (accountUser a)
          let n = userDisplayName (accountUser a)
          either
            (\e -> lift $ sendDeletionEmail n e k v l)
            (\p -> lift $ wrapClient $ sendDeletionSms p k v l)
            target
            `onException` wrapClientE (Code.delete k Code.AccountDeletion)
          return $! Just $! Code.codeTTL c

-- | Conclude validation and scheduling of user's deletion request that was initiated in
-- 'deleteUser'.  Called via @post /delete@.
verifyDeleteUser :: VerifyDeleteUser -> ExceptT DeleteUserError (AppT r) ()
verifyDeleteUser d = do
  let key = verifyDeleteUserKey d
  let code = verifyDeleteUserCode d
  c <- lift . wrapClient $ Code.verify key Code.AccountDeletion code
  a <- maybe (throwE DeleteUserInvalidCode) return (Code.codeAccount =<< c)
  account <- lift . wrapClient $ Data.lookupAccount (Id a)
  for_ account $ lift . wrapHttpClient . deleteAccount
  lift . wrapClient $ Code.delete key Code.AccountDeletion

-- | Internal deletion without validation.  Called via @delete /i/user/:uid@, or indirectly
-- via deleting self.
-- Team owners can be deleted if the team is not orphaned, i.e. there is at least one
-- other owner left.
deleteAccount ::
  ( MonadLogger m,
    MonadCatch m,
    MonadThrow m,
    MonadIndexIO m,
    MonadReader Env m,
    MonadIO m,
    MonadMask m,
    MonadHttp m,
    HasRequestId m,
    MonadUnliftIO m,
    MonadClient m
  ) =>
  UserAccount ->
  m ()
deleteAccount account@(accountUser -> user) = do
  let uid = userId user
  Log.info $ field "user" (toByteString uid) . msg (val "Deleting account")
  -- Free unique keys
  for_ (userEmail user) $ deleteKey . userEmailKey
  for_ (userPhone user) $ deleteKey . userPhoneKey
  for_ (userHandle user) $ freeHandle (userId user)
  -- Wipe data
  Data.clearProperties uid
  tombstone <- mkTombstone
  Data.insertAccount tombstone Nothing Nothing False
  Intra.rmUser uid (userAssets user)
  Data.lookupClients uid >>= mapM_ (Data.rmClient uid . clientId)
  luid <- qualifyLocal uid
  Intra.onUserEvent uid Nothing (UserDeleted (qUntagged luid))
  -- Note: Connections can only be deleted afterwards, since
  --       they need to be notified.
  Data.deleteConnections uid
  revokeAllCookies uid
  where
    mkTombstone = do
      defLoc <- setDefaultUserLocale <$> view settings
      return $
        account
          { accountStatus = Deleted,
            accountUser =
              user
                { userDisplayName = Name "default",
                  userAccentId = defaultAccentId,
                  userPict = noPict,
                  userAssets = [],
                  userHandle = Nothing,
                  userLocale = defLoc,
                  userIdentity = Nothing
                }
          }

-------------------------------------------------------------------------------
-- Lookups

lookupActivationCode ::
  (MonadIO m, MonadClient m) =>
  Either Email Phone ->
  m (Maybe ActivationPair)
lookupActivationCode emailOrPhone = do
  let uk = either userEmailKey userPhoneKey emailOrPhone
  k <- liftIO $ Data.mkActivationKey uk
  c <- fmap snd <$> Data.lookupActivationCode uk
  return $ (k,) <$> c

lookupPasswordResetCode :: Either Email Phone -> (AppT r) (Maybe PasswordResetPair)
lookupPasswordResetCode emailOrPhone = do
  let uk = either userEmailKey userPhoneKey emailOrPhone
  usr <- wrapClient $ Data.lookupKey uk
  case usr of
    Nothing -> return Nothing
    Just u -> do
      k <- liftIO $ Data.mkPasswordResetKey u
      c <- wrapClient $ Data.lookupPasswordResetCode u
      return $ (k,) <$> c

deleteUserNoVerify ::
  ( MonadReader Env m,
    MonadIO m,
    MonadLogger m,
    MonadThrow m
  ) =>
  UserId ->
  m ()
deleteUserNoVerify uid = do
  queue <- view internalEvents
  Queue.enqueue queue (Internal.DeleteUser uid)

deleteUsersNoVerify :: [UserId] -> (AppT r) ()
deleteUsersNoVerify uids = do
  for_ uids deleteUserNoVerify
  m <- view metrics
  Metrics.counterAdd (fromIntegral . length $ uids) (Metrics.path "user.enqueue_multi_delete_total") m
  Metrics.counterIncr (Metrics.path "user.enqueue_multi_delete_calls_total") m

-- | Garbage collect users if they're ephemeral and they have expired.
-- Always returns the user (deletion itself is delayed)
userGC ::
  ( MonadIO m,
    MonadReader Env m,
    MonadLogger m,
    MonadThrow m
  ) =>
  User ->
  m User
userGC u = case userExpire u of
  Nothing -> return u
  (Just (fromUTCTimeMillis -> e)) -> do
    now <- liftIO =<< view currentTime
    -- ephemeral users past their expiry date are deleted
    when (diffUTCTime e now < 0) $
      deleteUserNoVerify (userId u)
    return u

lookupProfile ::
  ( MonadClient m,
    MonadReader Env m,
    MonadLogger m,
    MonadMask m,
    MonadHttp m,
    HasRequestId m
  ) =>
  Local UserId ->
  Qualified UserId ->
  ExceptT FederationError m (Maybe UserProfile)
lookupProfile self other =
  listToMaybe
    <$> lookupProfilesFromDomain
      self
      (fmap pure other)

-- | Obtain user profiles for a list of users as they can be seen by
-- a given user 'self'. User 'self' can see the 'FullProfile' of any other user 'other',
-- if the reverse relation (other -> self) is either 'Accepted' or 'Sent'.
-- Otherwise only the 'PublicProfile' is accessible for user 'self'.
-- If 'self' is an unknown 'UserId', return '[]'.
lookupProfiles ::
  ( MonadUnliftIO m,
    MonadClient m,
    MonadReader Env m,
    MonadLogger m,
    MonadMask m,
    MonadHttp m,
    HasRequestId m
  ) =>
  -- | User 'self' on whose behalf the profiles are requested.
  Local UserId ->
  -- | The users ('others') for which to obtain the profiles.
  [Qualified UserId] ->
  ExceptT FederationError m [UserProfile]
lookupProfiles self others =
  concat
    <$> traverseConcurrentlyWithErrors
      (lookupProfilesFromDomain self)
      (bucketQualified others)

lookupProfilesFromDomain ::
  ( MonadClient m,
    MonadReader Env m,
    MonadLogger m,
    MonadMask m,
    MonadHttp m,
    HasRequestId m
  ) =>
  Local UserId ->
  Qualified [UserId] ->
  ExceptT FederationError m [UserProfile]
lookupProfilesFromDomain self =
  foldQualified
    self
    (lift . lookupLocalProfiles (Just (tUnqualified self)) . tUnqualified)
    lookupRemoteProfiles

lookupRemoteProfiles ::
  ( MonadIO m,
    MonadReader Env m,
    MonadLogger m
  ) =>
  Remote [UserId] ->
  ExceptT FederationError m [UserProfile]
lookupRemoteProfiles (qUntagged -> Qualified uids domain) =
  Federation.getUsersByIds domain uids

-- FUTUREWORK: This function encodes a few business rules about exposing email
-- ids, but it is also very complex. Maybe this can be made easy by extracting a
-- pure function and writing tests for that.
lookupLocalProfiles ::
  forall m.
  ( MonadClient m,
    MonadReader Env m,
    MonadLogger m,
    MonadMask m,
    MonadHttp m,
    HasRequestId m
  ) =>
  -- | This is present only when an authenticated user is requesting access.
  Maybe UserId ->
  -- | The users ('others') for which to obtain the profiles.
  [UserId] ->
  m [UserProfile]
lookupLocalProfiles requestingUser others = do
  users <- Data.lookupUsers NoPendingInvitations others >>= mapM userGC
  css <- case requestingUser of
    Just localReqUser -> toMap <$> Data.lookupConnectionStatus (map userId users) [localReqUser]
    Nothing -> pure mempty
  emailVisibility' <- view (settings . emailVisibility)
  emailVisibility'' <- case emailVisibility' of
    EmailVisibleIfOnTeam -> pure EmailVisibleIfOnTeam'
    EmailVisibleIfOnSameTeam -> case requestingUser of
      Just localReqUser -> EmailVisibleIfOnSameTeam' <$> getSelfInfo localReqUser
      Nothing -> pure EmailVisibleToSelf'
    EmailVisibleToSelf -> pure EmailVisibleToSelf'
  usersAndStatus <- for users $ \u -> (u,) <$> getLegalHoldStatus' u
  return $ map (toProfile emailVisibility'' css) usersAndStatus
  where
    toMap :: [ConnectionStatus] -> Map UserId Relation
    toMap = Map.fromList . map (csFrom &&& csStatus)

    getSelfInfo :: UserId -> m (Maybe (TeamId, Team.TeamMember))
    getSelfInfo selfId = do
      -- FUTUREWORK: it is an internal error for the two lookups (for 'User' and 'TeamMember')
      -- to return 'Nothing'.  we could throw errors here if that happens, rather than just
      -- returning an empty profile list from 'lookupProfiles'.
      mUser <- Data.lookupUser NoPendingInvitations selfId
      case userTeam =<< mUser of
        Nothing -> pure Nothing
        Just tid -> (tid,) <$$> Intra.getTeamMember selfId tid

    toProfile :: EmailVisibility' -> Map UserId Relation -> (User, UserLegalHoldStatus) -> UserProfile
    toProfile emailVisibility'' css (u, userLegalHold) =
      let cs = Map.lookup (userId u) css
          profileEmail' = getEmailForProfile u emailVisibility''
          baseProfile =
            if Just (userId u) == requestingUser || cs == Just Accepted || cs == Just Sent
              then connectedProfile u userLegalHold
              else publicProfile u userLegalHold
       in baseProfile {profileEmail = profileEmail'}

getLegalHoldStatus ::
  ( MonadLogger m,
    MonadReader Env m,
    MonadMask m,
    MonadHttp m,
    HasRequestId m,
    MonadClient m
  ) =>
  UserId ->
  m (Maybe UserLegalHoldStatus)
getLegalHoldStatus uid = traverse (getLegalHoldStatus' . accountUser) =<< lookupAccount uid

getLegalHoldStatus' ::
  ( MonadLogger m,
    MonadReader Env m,
    MonadIO m,
    MonadMask m,
    MonadHttp m,
    HasRequestId m
  ) =>
  User ->
  m UserLegalHoldStatus
getLegalHoldStatus' user =
  case userTeam user of
    Nothing -> pure defUserLegalHoldStatus
    Just tid -> do
      teamMember <- Intra.getTeamMember (userId user) tid
      pure $ maybe defUserLegalHoldStatus (^. legalHoldStatus) teamMember

data EmailVisibility'
  = EmailVisibleIfOnTeam'
  | EmailVisibleIfOnSameTeam' (Maybe (TeamId, Team.TeamMember))
  | EmailVisibleToSelf'

-- | Gets the email if it's visible to the requester according to configured settings
getEmailForProfile ::
  User ->
  EmailVisibility' ->
  Maybe Email
getEmailForProfile profileOwner EmailVisibleIfOnTeam' =
  if isJust (userTeam profileOwner)
    then userEmail profileOwner
    else Nothing
getEmailForProfile profileOwner (EmailVisibleIfOnSameTeam' (Just (viewerTeamId, viewerTeamMember))) =
  if Just viewerTeamId == userTeam profileOwner
    && Team.hasPermission viewerTeamMember Team.ViewSameTeamEmails
    then userEmail profileOwner
    else Nothing
getEmailForProfile _ (EmailVisibleIfOnSameTeam' Nothing) = Nothing
getEmailForProfile _ EmailVisibleToSelf' = Nothing

-- | Find user accounts for a given identity, both activated and those
-- currently pending activation.
lookupAccountsByIdentity :: Either Email Phone -> Bool -> (AppT r) [UserAccount]
lookupAccountsByIdentity emailOrPhone includePendingInvitations = do
  let uk = either userEmailKey userPhoneKey emailOrPhone
  activeUid <- wrapClient $ Data.lookupKey uk
  uidFromKey <- (>>= fst) <$> wrapClient (Data.lookupActivationCode uk)
  result <- wrapClient $ Data.lookupAccounts (nub $ catMaybes [activeUid, uidFromKey])
  if includePendingInvitations
    then pure result
    else pure $ filter ((/= PendingInvitation) . accountStatus) result

isBlacklisted :: Either Email Phone -> (AppT r) Bool
isBlacklisted emailOrPhone = do
  let uk = either userEmailKey userPhoneKey emailOrPhone
  wrapClient $ Blacklist.exists uk

blacklistInsert :: Either Email Phone -> (AppT r) ()
blacklistInsert emailOrPhone = do
  let uk = either userEmailKey userPhoneKey emailOrPhone
  wrapClient $ Blacklist.insert uk

blacklistDelete :: Either Email Phone -> (AppT r) ()
blacklistDelete emailOrPhone = do
  let uk = either userEmailKey userPhoneKey emailOrPhone
  wrapClient $ Blacklist.delete uk

phonePrefixGet :: PhonePrefix -> (AppT r) [ExcludedPrefix]
phonePrefixGet = wrapClient . Blacklist.getAllPrefixes

phonePrefixDelete :: PhonePrefix -> (AppT r) ()
phonePrefixDelete = wrapClient . Blacklist.deletePrefix

phonePrefixInsert :: ExcludedPrefix -> (AppT r) ()
phonePrefixInsert = wrapClient . Blacklist.insertPrefix
