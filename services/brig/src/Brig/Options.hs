{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

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

module Brig.Options where

import Brig.Queue.Types (Queue (..))
import Brig.SMTP (SMTPConnType (..))
import Brig.Types
import Brig.User.Auth.Cookie.Limit
import Brig.Whitelist (Whitelist (..))
import qualified Brig.ZAuth as ZAuth
import Control.Applicative
import qualified Control.Lens as Lens
import Data.Aeson (defaultOptions, fieldLabelModifier, genericParseJSON, withText)
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (typeMismatch)
import qualified Data.Char as Char
import qualified Data.Code as Code
import Data.Domain (Domain (..))
import Data.Id
import Data.LanguageCodes (ISO639_1 (EN))
import Data.Misc (HttpsUrl)
import Data.Range
import Data.Schema
import Data.Scientific (toBoundedInteger)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Time.Clock (DiffTime, NominalDiffTime, secondsToDiffTime)
import Data.Yaml (FromJSON (..), ToJSON (..), (.:), (.:?))
import qualified Data.Yaml as Y
import Imports
import qualified Network.DNS as DNS
import System.Logger.Extended (Level, LogFormat)
import Util.Options
import Wire.API.Arbitrary (Arbitrary, GenericUniform (GenericUniform))
import qualified Wire.API.Team.Feature as ApiFT
import Wire.API.User.Search (FederatedUserSearchPolicy)

newtype Timeout = Timeout
  { timeoutDiff :: NominalDiffTime
  }
  deriving newtype (Eq, Enum, Ord, Num, Real, Fractional, RealFrac, Show)

instance Read Timeout where
  readsPrec i s =
    case readsPrec i s of
      [(x :: Int, s')] -> [(Timeout (fromIntegral x), s')]
      _ -> []

data ElasticSearchOpts = ElasticSearchOpts
  { -- | ElasticSearch URL
    url :: !Text,
    -- | The name of the ElasticSearch user index
    index :: !Text,
    -- | An additional index to write user data, useful while migrating to a new
    -- index.
    -- There is a bug hidden when using this option. Sometimes a user won't get
    -- deleted from the index. Attempts at reproducing this issue in a simpler
    -- environment have failed. As a workaround, there is a tool in
    -- tools/db/find-undead which can be used to find the undead users right
    -- after the migration, if they exist, we can run the reindexing to get data
    -- in elasticsearch in a consistent state.
    additionalWriteIndex :: !(Maybe Text),
    -- | An additional ES URL to write user data, useful while migrating to a
    -- new instace of ES. It is necessary to provide 'additionalWriteIndex' for
    -- this to be used. If this is 'Nothing' and 'additionalWriteIndex' is
    -- configured, the 'url' field will be used.
    additionalWriteIndexUrl :: !(Maybe Text)
  }
  deriving (Show, Generic)

instance FromJSON ElasticSearchOpts

data AWSOpts = AWSOpts
  { -- | Event journal queue for user events
    --   (e.g. user deletion)
    userJournalQueue :: !(Maybe Text),
    -- | Dynamo table for storing prekey data
    prekeyTable :: !Text,
    -- | AWS SQS endpoint
    sqsEndpoint :: !AWSEndpoint,
    -- | DynamoDB endpoint
    dynamoDBEndpoint :: !(Maybe AWSEndpoint)
  }
  deriving (Show, Generic)

instance FromJSON AWSOpts

data EmailAWSOpts = EmailAWSOpts
  { -- | Event feedback queue for SES
    --   (e.g. for email bounces and complaints)
    sesQueue :: !Text,
    -- | AWS SES endpoint
    sesEndpoint :: !AWSEndpoint
  }
  deriving (Show, Generic)

instance FromJSON EmailAWSOpts

data EmailSMTPCredentials = EmailSMTPCredentials
  { -- | Username to authenticate
    --   against the SMTP server
    smtpUsername :: !Text,
    -- | File containing password to
    --   authenticate against the SMTP server
    smtpPassword :: !FilePathSecrets
  }
  deriving (Show, Generic)

instance FromJSON EmailSMTPCredentials

data EmailSMTPOpts = EmailSMTPOpts
  { -- | Hostname of the SMTP server to connect to
    smtpEndpoint :: !Endpoint,
    smtpCredentials :: !(Maybe EmailSMTPCredentials),
    -- | Which type of connection to use
    --   against the SMTP server {tls,ssl,plain}
    smtpConnType :: !SMTPConnType
  }
  deriving (Show, Generic)

instance FromJSON EmailSMTPOpts

data StompOpts = StompOpts
  { stompHost :: !Text,
    stompPort :: !Int,
    stompTls :: !Bool
  }
  deriving (Show, Generic)

instance FromJSON StompOpts

data InternalEventsOpts = InternalEventsOpts
  { internalEventsQueue :: !Queue
  }
  deriving (Show)

instance FromJSON InternalEventsOpts where
  parseJSON = Y.withObject "InternalEventsOpts" $ \o ->
    InternalEventsOpts <$> parseJSON (Y.Object o)

data EmailSMSGeneralOpts = EmailSMSGeneralOpts
  { -- | Email, SMS, ... template directory
    templateDir :: !FilePath,
    -- | Email sender address
    emailSender :: !Email,
    -- | Twilio sender identifier (sender phone number in E.104 format)
    --   or twilio messaging sender ID - see
    --   https://www.twilio.com/docs/sms/send-messages#use-an-alphanumeric-sender-id
    smsSender :: !Text,
    -- | Customizable branding text for
    --   emails/sms/calls
    templateBranding :: !BrandingOpts
  }
  deriving (Show, Generic)

instance FromJSON EmailSMSGeneralOpts

data BrandingOpts = BrandingOpts
  { brand :: !Text,
    brandUrl :: !Text,
    brandLabelUrl :: !Text,
    brandLogoUrl :: !Text,
    brandService :: !Text,
    copyright :: !Text,
    misuse :: !Text,
    legal :: !Text,
    forgot :: !Text,
    support :: !Text
  }
  deriving (Show, Generic)

instance FromJSON BrandingOpts

data EmailUserOpts = EmailUserOpts
  { -- | Activation URL template
    activationUrl :: !Text,
    -- | SMS activation URL template
    smsActivationUrl :: !Text,
    -- | Password reset URL template
    passwordResetUrl :: !Text,
    -- | Deletion URL template
    deletionUrl :: !Text
  }
  deriving (Show, Generic)

instance FromJSON EmailUserOpts

-- | Provider settings
data ProviderOpts = ProviderOpts
  { -- | Homepage URL
    homeUrl :: !Text,
    -- | Activation URL template
    providerActivationUrl :: !Text,
    -- | Approval URL template
    approvalUrl :: !Text,
    -- | Approval email recipient
    approvalTo :: !Email,
    -- | Password reset URL template
    providerPwResetUrl :: !Text
  }
  deriving (Show, Generic)

instance FromJSON ProviderOpts

data TeamOpts = TeamOpts
  { -- | Team Invitation URL template
    tInvitationUrl :: !Text,
    -- | Team Activation URL template
    tActivationUrl :: !Text,
    -- | Team Creator Welcome URL
    tCreatorWelcomeUrl :: !Text,
    -- | Team Member Welcome URL
    tMemberWelcomeUrl :: !Text
  }
  deriving (Show, Generic)

instance FromJSON TeamOpts

data EmailOpts
  = EmailAWS EmailAWSOpts
  | EmailSMTP EmailSMTPOpts
  deriving (Show, Generic)

instance FromJSON EmailOpts where
  parseJSON o =
    EmailAWS <$> parseJSON o
      <|> EmailSMTP <$> parseJSON o

data EmailSMSOpts = EmailSMSOpts
  { email :: !EmailOpts,
    general :: !EmailSMSGeneralOpts,
    user :: !EmailUserOpts,
    provider :: !ProviderOpts,
    team :: !TeamOpts
  }
  deriving (Show, Generic)

instance FromJSON EmailSMSOpts

-- | Login retry limit.  In contrast to 'setUserCookieThrottle', this is not about mitigating
-- DOS attacks, but about preventing dictionary attacks.  This introduces the orthogonal risk
-- of an attacker blocking legitimate login attempts of a user by constantly keeping the retry
-- limit for that user exhausted with failed login attempts.
--
-- If in doubt, do not ues retry options and worry about encouraging / enforcing a good
-- password policy.
data LimitFailedLogins = LimitFailedLogins
  { -- | Time the user is blocked when retry limit is reached (in
    -- seconds mostly for making it easier to write a fast-ish
    -- integration test.)
    timeout :: !Timeout,
    -- | Maximum number of failed login attempts for one user.
    retryLimit :: !Int
  }
  deriving (Eq, Show, Generic)

instance FromJSON LimitFailedLogins

data SuspendInactiveUsers = SuspendInactiveUsers
  { suspendTimeout :: !Timeout
  }
  deriving (Eq, Show, Generic)

instance FromJSON SuspendInactiveUsers

-- | ZAuth options
data ZAuthOpts = ZAuthOpts
  { -- | Private key file
    privateKeys :: !FilePath,
    -- | Public key file
    publicKeys :: !FilePath,
    -- | Other settings
    authSettings :: !ZAuth.Settings
  }
  deriving (Show, Generic)

instance FromJSON ZAuthOpts

-- | TURN server options
data TurnOpts = TurnOpts
  { -- | Line separated file with IP addresses of
    --   available TURN servers supporting UDP
    servers :: !FilePath,
    -- | Line separated file with hostnames of all
    --   available TURN servers with all protocols
    --   and transports
    serversV2 :: !FilePath,
    -- | TURN shared secret file path
    secret :: !FilePath,
    -- | For how long TURN credentials should be
    --   valid, in seconds
    tokenTTL :: !Word32,
    -- | How long until a new TURN configuration
    --   should be fetched, in seconds
    configTTL :: !Word32
  }
  deriving (Show, Generic)

instance FromJSON TurnOpts

-- | Configurations for whether to show a user's email to others.
data EmailVisibility
  = -- | Anyone can see the email of someone who is on ANY team.
    --         This may sound strange; but certain on-premise hosters have many different teams
    --         and still want them to see each-other's emails.
    EmailVisibleIfOnTeam
  | -- | Anyone on your team with at least 'Member' privileges can see your email address.
    EmailVisibleIfOnSameTeam
  | -- | Show your email only to yourself
    EmailVisibleToSelf
  deriving (Eq, Show, Bounded, Enum)

instance FromJSON EmailVisibility where
  parseJSON = withText "EmailVisibility" $ \case
    "visible_if_on_team" -> pure EmailVisibleIfOnTeam
    "visible_if_on_same_team" -> pure EmailVisibleIfOnSameTeam
    "visible_to_self" -> pure EmailVisibleToSelf
    _ ->
      fail $
        "unexpected value for EmailVisibility settings: "
          <> "expected one of "
          <> show (Aeson.encode <$> [(minBound :: EmailVisibility) ..])

instance ToJSON EmailVisibility where
  toJSON EmailVisibleIfOnTeam = "visible_if_on_team"
  toJSON EmailVisibleIfOnSameTeam = "visible_if_on_same_team"
  toJSON EmailVisibleToSelf = "visible_to_self"

data ListAllSFTServers
  = ListAllSFTServers
  | HideAllSFTServers
  deriving (Show, Eq, Ord)
  deriving (FromJSON) via Schema ListAllSFTServers

instance ToSchema ListAllSFTServers where
  schema =
    enum @Text "ListSFTServers" $
      mconcat
        [ element "enabled" ListAllSFTServers,
          element "disabled" HideAllSFTServers
        ]

data AllowedUserSearch
  = NoSearch
  | ExactHandleSearch
  | FullSearch
  deriving (Show, Generic, Enum, Bounded)

instance ToJSON AllowedUserSearch where
  toJSON NoSearch = "no_search"
  toJSON ExactHandleSearch = "exact_handle_search"
  toJSON FullSearch = "full_search"

instance FromJSON AllowedUserSearch where
  parseJSON = withText "AllowedUserSearch" $ \case
    "no_search" -> pure NoSearch
    "exact_handle_search" -> pure ExactHandleSearch
    "full_search" -> pure FullSearch
    _ ->
      fail $
        "unexpected value for AllowedUserSearch settings: "
          <> "expected one of "
          <> show (Aeson.encode <$> [(minBound :: AllowedUserSearch) ..])

data FederationDomainConfig = FederationDomainConfig
  { domain :: Domain,
    cfgSearchPolicy :: FederatedUserSearchPolicy
  }
  deriving (Show, Generic)
  deriving (ToJSON, FromJSON) via Schema FederationDomainConfig

instance ToSchema FederationDomainConfig where
  schema =
    object "FederationDomainConfig" $
      FederationDomainConfig
        <$> domain .= field "domain" schema
        <*> cfgSearchPolicy .= field "search_policy" schema

-- | Options that are consumed on startup
data Opts = Opts
  -- services
  { -- | Host and port to bind to
    brig :: !Endpoint,
    -- | Cargohold address
    cargohold :: !Endpoint,
    -- | Galley address
    galley :: !Endpoint,
    -- | Gundeck address
    gundeck :: !Endpoint,
    -- | Federator address
    federatorInternal :: !(Maybe Endpoint),
    -- external

    -- | Cassandra settings
    cassandra :: !CassandraOpts,
    -- | ElasticSearch settings
    elasticsearch :: !ElasticSearchOpts,
    -- | AWS settings
    aws :: !AWSOpts,
    -- | Enable Random Prekey Strategy
    randomPrekeys :: !(Maybe Bool),
    -- | STOMP broker settings
    stomp :: !(Maybe StompOpts),
    -- Email & SMS

    -- | Email and SMS settings
    emailSMS :: !EmailSMSOpts,
    -- ZAuth

    -- | ZAuth settings
    zauth :: !ZAuthOpts,
    -- Misc.

    -- | Disco URL
    discoUrl :: !(Maybe Text),
    -- | GeoDB file path
    geoDb :: !(Maybe FilePath),
    -- | Event queue for
    --   Brig-generated events (e.g.
    --   user deletion)
    internalEvents :: !InternalEventsOpts,
    -- Logging

    -- | Log level (Debug, Info, etc)
    logLevel :: !Level,
    -- | Use netstrings encoding (see
    --   <http://cr.yp.to/proto/netstrings.txt>)
    logNetStrings :: !(Maybe (Last Bool)),
    -- | Logformat to use
    -- TURN
    logFormat :: !(Maybe (Last LogFormat)),
    -- | TURN server settings
    turn :: !TurnOpts,
    -- | SFT Settings
    sft :: !(Maybe SFTOptions),
    -- | Runtime settings
    optSettings :: !Settings
  }
  deriving (Show, Generic)

-- | Options that persist as runtime settings.
data Settings = Settings
  { -- | Activation timeout, in seconds
    setActivationTimeout :: !Timeout,
    -- | Default verification code timeout, in seconds
    -- use `setVerificationTimeout` as the getter function which always provides a default value
    setVerificationCodeTimeoutInternal :: !(Maybe Code.Timeout),
    -- | Team invitation timeout, in seconds
    setTeamInvitationTimeout :: !Timeout,
    -- | Check for expired users every so often, in seconds
    setExpiredUserCleanupTimeout :: !(Maybe Timeout),
    -- | Twilio credentials
    setTwilio :: !FilePathSecrets,
    -- | Nexmo credentials
    setNexmo :: !FilePathSecrets,
    -- | STOMP broker credentials
    setStomp :: !(Maybe FilePathSecrets),
    -- | Whitelist of allowed emails/phones
    setWhitelist :: !(Maybe Whitelist),
    -- | Max. number of sent/accepted
    --   connections per user
    setUserMaxConnections :: !Int64,
    -- | Max. number of permanent clients per user
    setUserMaxPermClients :: !(Maybe Int),
    -- | Whether to allow plain HTTP transmission
    --   of cookies (for testing purposes only)
    setCookieInsecure :: !Bool,
    -- | Minimum age of a user cookie before
    --   it is renewed during token refresh
    setUserCookieRenewAge :: !Integer,
    -- | Max. # of cookies per user and cookie type
    setUserCookieLimit :: !Int,
    -- | Throttling settings (not to be confused
    -- with 'LoginRetryOpts')
    setUserCookieThrottle :: !CookieThrottle,
    -- | Block user from logging in
    -- for m minutes after n failed
    -- logins
    setLimitFailedLogins :: !(Maybe LimitFailedLogins),
    -- | If last cookie renewal is too long ago,
    -- suspend the user.
    setSuspendInactiveUsers :: !(Maybe SuspendInactiveUsers),
    -- | Max size of rich info (number of chars in
    --   field names and values), should be in sync
    --   with Spar
    setRichInfoLimit :: !Int,
    -- | Default locale to use when selecting templates
    -- use `setDefaultTemplateLocale` as the getter function which always provides a default value
    setDefaultTemplateLocaleInternal :: !(Maybe Locale),
    -- | Default locale to use for users
    -- use `setDefaultUserLocale` as the getter function which always provides a default value
    setDefaultUserLocaleInternal :: !(Maybe Locale),
    -- | Max. # of members in a team.
    --   NOTE: This must be in sync with galley
    setMaxTeamSize :: !Word32,
    -- | Max. # of members in a conversation.
    --   NOTE: This must be in sync with galley
    setMaxConvSize :: !Word16,
    -- | Filter ONLY services with
    --   the given provider id
    setProviderSearchFilter :: !(Maybe ProviderId),
    -- | Whether to expose user emails and to whom
    setEmailVisibility :: !EmailVisibility,
    setPropertyMaxKeyLen :: !(Maybe Int64),
    setPropertyMaxValueLen :: !(Maybe Int64),
    -- | How long, in milliseconds, to wait
    -- in between processing delete events
    -- from the internal delete queue
    setDeleteThrottleMillis :: !(Maybe Int),
    -- | When true, search only
    -- returns users from the same team
    setSearchSameTeamOnly :: !(Maybe Bool),
    -- | FederationDomain is required, even when not wanting to federate with other backends
    -- (in that case the 'allowedDomains' can be set to empty in Federator)
    -- Federation domain is used to qualify local IDs and handles,
    -- e.g. 0c4d8944-70fa-480e-a8b7-9d929862d18c@wire.com and somehandle@wire.com.
    -- It should also match the SRV DNS records under which other wire-server installations can find this backend:
    --    _wire-server-federator._tcp.<federationDomain>
    -- Once set, DO NOT change it: if you do, existing users may have a broken experience and/or stop working
    -- Remember to keep it the same in Galley.
    -- Example:
    --   allowedDomains:
    --     - wire.com
    --     - example.com
    setFederationDomain :: !Domain,
    setFederationDomainConfigs :: !(Maybe [FederationDomainConfig]),
    -- | The amount of time in milliseconds to wait after reading from an SQS queue
    -- returns no message, before asking for messages from SQS again.
    -- defaults to 'defSqsThrottleMillis'.
    -- When using real SQS from AWS, throttling isn't needed as much, since using
    --   SQS.rmWaitTimeSeconds (Just 20) in Brig.AWS.listen
    -- ensures that there is only one request every 20 seconds.
    -- However, that parameter is not honoured when using fake-sqs
    -- (where throttling can thus make sense)
    setSqsThrottleMillis :: !(Maybe Int),
    -- | Do not allow certain user creation flows.
    -- docs/reference/user/registration.md {#RefRestrictRegistration}.
    setRestrictUserCreation :: !(Maybe Bool),
    -- | The analog to `Galley.Options.setFeatureFlags`.  See 'AccountFeatureConfigs'.
    setFeatureFlags :: !(Maybe AccountFeatureConfigs),
    -- | Customer extensions.  Read 'CustomerExtensions' docs carefully!
    setCustomerExtensions :: !(Maybe CustomerExtensions),
    -- | When set; instead of using SRV lookups to discover SFTs the calls
    -- config will always return this entry. This is useful in Kubernetes
    -- where SFTs are deployed behind a load-balancer.  In the long-run the SRV
    -- fetching logic can go away completely
    setSftStaticUrl :: !(Maybe HttpsUrl),
    -- | When set the /calls/config/v2 endpoint will include all the
    -- loadbalanced servers of `setSftStaticUrl` under the @sft_servers_all@
    -- field. The default setting is to exclude and omit the field from the
    -- response.
    setSftListAllServers :: Maybe ListAllSFTServers,
    setKeyPackageMaximumLifetime :: Maybe NominalDiffTime
  }
  deriving (Show, Generic)

defaultTemplateLocale :: Locale
defaultTemplateLocale = Locale (Language EN) Nothing

defaultUserLocale :: Locale
defaultUserLocale = defaultTemplateLocale

setDefaultUserLocale :: Settings -> Locale
setDefaultUserLocale = fromMaybe defaultUserLocale . setDefaultUserLocaleInternal

defVerificationTimeout :: Code.Timeout
defVerificationTimeout = Code.Timeout (60 * 10) -- 10 minutes

setVerificationTimeout :: Settings -> Code.Timeout
setVerificationTimeout = fromMaybe defVerificationTimeout . setVerificationCodeTimeoutInternal

setDefaultTemplateLocale :: Settings -> Locale
setDefaultTemplateLocale = fromMaybe defaultTemplateLocale . setDefaultTemplateLocaleInternal

-- | The analog to `GT.FeatureFlags`.  This type tracks only the things that we need to
-- express our current cloud business logic.
--
-- FUTUREWORK: it would be nice to have a system of feature configs that allows to coherently
-- express arbitrary logic accross personal and team accounts, teams, and instances; including
-- default values for new records, default for records that have a NULL value (eg., because
-- they are grandfathered), and feature-specific extra data (eg., TLL for self-deleting
-- messages).  For now, we have something quick & simple.
data AccountFeatureConfigs = AccountFeatureConfigs
  { afcConferenceCallingDefNew :: !(ApiFT.TeamFeatureStatus 'ApiFT.WithoutLockStatus 'ApiFT.TeamFeatureConferenceCalling),
    afcConferenceCallingDefNull :: !(ApiFT.TeamFeatureStatus 'ApiFT.WithoutLockStatus 'ApiFT.TeamFeatureConferenceCalling)
  }
  deriving (Show, Eq, Generic)
  deriving (Arbitrary) via (GenericUniform AccountFeatureConfigs)

instance FromJSON AccountFeatureConfigs where
  parseJSON =
    Aeson.withObject
      "AccountFeatureConfigs"
      ( \obj -> do
          confCallInit <- obj Aeson..: "conferenceCalling"
          Aeson.withObject
            "conferenceCalling"
            ( \obj' -> do
                AccountFeatureConfigs
                  <$> obj' Aeson..: "defaultForNew"
                  <*> obj' Aeson..: "defaultForNull"
            )
            confCallInit
      )

instance ToJSON AccountFeatureConfigs where
  toJSON
    AccountFeatureConfigs
      { afcConferenceCallingDefNew,
        afcConferenceCallingDefNull
      } =
      Aeson.object
        [ "conferenceCalling"
            Aeson..= Aeson.object
              [ "defaultForNew" Aeson..= afcConferenceCallingDefNew,
                "defaultForNull" Aeson..= afcConferenceCallingDefNull
              ]
        ]

getAfcConferenceCallingDefNewMaybe :: Lens.Getter Settings (Maybe ApiFT.TeamFeatureStatusNoConfig)
getAfcConferenceCallingDefNewMaybe = Lens.to (Lens.^? (Lens.to setFeatureFlags . Lens._Just . Lens.to afcConferenceCallingDefNew))

getAfcConferenceCallingDefNullMaybe :: Lens.Getter Settings (Maybe ApiFT.TeamFeatureStatusNoConfig)
getAfcConferenceCallingDefNullMaybe = Lens.to (Lens.^? (Lens.to setFeatureFlags . Lens._Just . Lens.to afcConferenceCallingDefNull))

getAfcConferenceCallingDefNew :: Lens.Getter Settings ApiFT.TeamFeatureStatusNoConfig
getAfcConferenceCallingDefNew = Lens.to (afcConferenceCallingDefNew . fromMaybe defAccountFeatureConfigs . setFeatureFlags)

getAfcConferenceCallingDefNull :: Lens.Getter Settings ApiFT.TeamFeatureStatusNoConfig
getAfcConferenceCallingDefNull = Lens.to (afcConferenceCallingDefNull . fromMaybe defAccountFeatureConfigs . setFeatureFlags)

defAccountFeatureConfigs :: AccountFeatureConfigs
defAccountFeatureConfigs =
  AccountFeatureConfigs
    { afcConferenceCallingDefNew = ApiFT.TeamFeatureStatusNoConfig ApiFT.TeamFeatureEnabled,
      afcConferenceCallingDefNull = ApiFT.TeamFeatureStatusNoConfig ApiFT.TeamFeatureEnabled
    }

-- | Customer extensions naturally are covered by the AGPL like everything else, but use them
-- at your own risk!  If you use the default server config and do not set
-- @customerExtensions@, none of this will have any effect.
--
-- This is code implemented to comply with particular contracts.  It may change or be removed
-- at any point in the future without any further notice.
data CustomerExtensions = CustomerExtensions
  { -- | You cannot create an account (free user without team or user with new team) if your
    -- email address has a domain listed here.  You can only accept an invitation from a team
    -- that has already been created.
    --
    -- This feature is a work-around for issues with our somewhat convoluted onboarding
    -- process.  We are working on a more sustainable solution.  Meanwhile this should not be
    -- used unless absolutely necessary (legal reasons, constracts).  It has numerous
    -- drawbacks:
    --
    -- * Changing it requires changing the configuration of the backend, which usually means
    --   a new release.  This is intentional to keep this feature from contaminating more of
    --   the code base (see below), but it also makes it awkward to use.
    --
    -- * So far, we have been using emails as opaque identifiers and not made any assumptions
    --   about their structure.  Now, email is still securely associated with a user, but can
    --   also be securely associated with another user who owns the first user's domain.  This
    --   new setup is more complex, and complexity is bad for security.  Security is now based
    --   on a much larger number of assumptions, and any one of these assumptions can be
    --   broken by software or usage errors.  Example: is it even legal for the owner of an
    --   email domain to keep users from signing up with wire using that email?  This is
    --   possibly true for domains like @mystartup.com@, but what about
    --   @globalmailhosting.com@?  Other example: next point.
    --
    -- * We could implement something more sophisticated involving 'TXT' DNS records that the
    --   team admin needs to set up containing some secrets obtainable via team settings.
    --   This is a lot more involved to implement, and very easy for coders or users to get
    --   wrong.
    --
    -- Bottom line: you probably want to keep either @customerExtensions = Nothing@ or at
    -- least @domainsBlockedForRegistration = []@.  :)
    domainsBlockedForRegistration :: DomainsBlockedForRegistration
  }
  deriving (Show, FromJSON, Generic)

-- | See also: "Galley.API.CustomBackend", `galley.custom_backend`.
newtype DomainsBlockedForRegistration = DomainsBlockedForRegistration [Domain]
  deriving newtype (Show, FromJSON, Generic)

data SFTOptions = SFTOptions
  { sftBaseDomain :: !DNS.Domain,
    sftSRVServiceName :: !(Maybe ByteString), -- defaults to defSftServiceName if unset
    sftDiscoveryIntervalSeconds :: !(Maybe DiffTime), -- defaults to defSftDiscoveryIntervalSeconds
    sftListLength :: !(Maybe (Range 1 100 Int)) -- defaults to defSftListLength
  }
  deriving (Show, Generic)

instance FromJSON SFTOptions where
  parseJSON = Y.withObject "SFTOptions" $ \o ->
    SFTOptions
      <$> (asciiOnly =<< o .: "sftBaseDomain")
      <*> (mapM asciiOnly =<< o .:? "sftSRVServiceName")
      <*> (secondsToDiffTime <$$> o .:? "sftDiscoveryIntervalSeconds")
      <*> (o .:? "sftListLength")
    where
      asciiOnly :: Text -> Y.Parser ByteString
      asciiOnly t =
        if Text.all Char.isAscii t
          then pure $ Text.encodeUtf8 t
          else fail $ "Expected ascii string only, found: " <> Text.unpack t

defMaxKeyLen :: Int64
defMaxKeyLen = 1024

defMaxValueLen :: Int64
defMaxValueLen = 524288

defDeleteThrottleMillis :: Int
defDeleteThrottleMillis = 100

defSqsThrottleMillis :: Int
defSqsThrottleMillis = 500

defUserMaxPermClients :: Int
defUserMaxPermClients = 7

defSftServiceName :: ByteString
defSftServiceName = "_sft"

defSftDiscoveryIntervalSeconds :: DiffTime
defSftDiscoveryIntervalSeconds = secondsToDiffTime 10

defSftListLength :: Range 1 100 Int
defSftListLength = unsafeRange 5

instance FromJSON Timeout where
  parseJSON (Y.Number n) =
    let defaultV = 3600
        bounded = toBoundedInteger n :: Maybe Int64
     in pure $
          Timeout $
            fromIntegral @Int $
              maybe defaultV fromIntegral bounded
  parseJSON v = typeMismatch "activationTimeout" v

instance FromJSON Settings where
  parseJSON = genericParseJSON customOptions
    where
      customOptions =
        defaultOptions
          { fieldLabelModifier = \case
              "setDefaultUserLocaleInternal" -> "setDefaultUserLocale"
              "setDefaultTemplateLocaleInternal" -> "setDefaultTemplateLocale"
              "setVerificationCodeTimeoutInternal" -> "setVerificationTimeout"
              other -> other
          }

instance FromJSON Opts

-- TODO: Does it make sense to generate lens'es for all?
Lens.makeLensesFor
  [ ("optSettings", "optionSettings"),
    ("elasticsearch", "elasticsearchL"),
    ("sft", "sftL")
  ]
  ''Opts

Lens.makeLensesFor
  [ ("setEmailVisibility", "emailVisibility"),
    ("setPropertyMaxKeyLen", "propertyMaxKeyLen"),
    ("setPropertyMaxValueLen", "propertyMaxValueLen"),
    ("setSearchSameTeamOnly", "searchSameTeamOnly"),
    ("setUserMaxPermClients", "userMaxPermClients"),
    ("setFederationDomain", "federationDomain"),
    ("setSqsThrottleMillis", "sqsThrottleMillis"),
    ("setSftStaticUrl", "sftStaticUrl"),
    ("setSftListAllServers", "sftListAllServers"),
    ("setFederationDomainConfigs", "federationDomainConfigs")
  ]
  ''Settings

Lens.makeLensesFor
  [ ("url", "urlL"),
    ("index", "indexL"),
    ("additionalWriteIndex", "additionalWriteIndexL"),
    ("additionalWriteIndexUrl", "additionalWriteIndexUrlL")
  ]
  ''ElasticSearchOpts

Lens.makeLensesFor [("sftBaseDomain", "sftBaseDomainL")] ''SFTOptions
