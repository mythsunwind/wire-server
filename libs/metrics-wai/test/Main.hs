{-# OPTIONS_GHC -Wno-unused-imports #-}

module Main (main) where

import Imports
import Data.Metrics.Middleware.Prometheus
import Data.Metrics.Types
import Data.Metrics.WaiRoute
import Data.Tree
import Network.Wai
import Network.Wai.Routing.Route


-- | FUTUREWORK: once we have a second test case, introduce hspec or tasty or whatever.
main :: IO ()
main = do
  test_treeLookup
  test_normalizeWaiRequestRoute'

test_treeLookup :: IO ()
test_treeLookup = unless (want == haveNaive && want == haveReal) $ do
    error $ show (want, haveNaive, haveReal)
  where
    want = Just "/a/:d/c"

    haveNaive = treeLookupNaive a b
    haveReal  = treeLookup (fromRight undefined $ mkTree a) b

    a = [["a", "b", "c"], ["a", ":d", "c"]]
    b = ["a", "d", "c"]

test_normalizeWaiRequestRoute' :: IO ()
test_normalizeWaiRequestRoute' = unless (want == have) . error $ show (want, have)
  where
    want = "/i/users/:id/reauthenticate"
    have = normalizeWaiRequestRoute' brigPaths "oops" ["i","users","bla","reauthenticate"]

brigPaths :: Paths
brigPaths = Paths [Node {rootLabel = Right "users", subForest = [Node {rootLabel = Right "prekeys", subForest = []},Node {rootLabel = Right "handles", subForest = [Node {rootLabel = Left ":handle", subForest = []}]},Node {rootLabel = Right "api-docs", subForest = []},Node {rootLabel = Left ":user", subForest = [Node {rootLabel = Right "rich-info", subForest = []},Node {rootLabel = Right "prekeys", subForest = [Node {rootLabel = Left ":client", subForest = []}]},Node {rootLabel = Right "clients", subForest = [Node {rootLabel = Left ":client", subForest = []}]}]},Node {rootLabel = Left ":id", subForest = []}]},Node {rootLabel = Right "teams", subForest = [Node {rootLabel = Right "invitations", subForest = [Node {rootLabel = Right "info", subForest = []}]},Node {rootLabel = Left ":tid", subForest = [Node {rootLabel = Right "services", subForest = [Node {rootLabel = Right "whitelisted", subForest = []},Node {rootLabel = Right "whitelist", subForest = []}]},Node {rootLabel = Right "invitations", subForest = [Node {rootLabel = Left ":iid", subForest = []}]}]}]},Node {rootLabel = Right "services", subForest = [Node {rootLabel = Right "tags", subForest = []}]},Node {rootLabel = Right "self", subForest = [Node {rootLabel = Right "searchable", subForest = []},Node {rootLabel = Right "phone", subForest = []},Node {rootLabel = Right "password", subForest = []},Node {rootLabel = Right "name", subForest = []},Node {rootLabel = Right "locale", subForest = []},Node {rootLabel = Right "handle", subForest = []},Node {rootLabel = Right "email", subForest = []}]},Node {rootLabel = Right "search", subForest = [Node {rootLabel = Right "contacts", subForest = []}]},Node {rootLabel = Right "register", subForest = []},Node {rootLabel = Right "providers", subForest = [Node {rootLabel = Left ":pid", subForest = [Node {rootLabel = Right "services", subForest = [Node {rootLabel = Left ":sid", subForest = []}]}]}]},Node {rootLabel = Right "provider", subForest = [Node {rootLabel = Right "services", subForest = [Node {rootLabel = Left ":sid", subForest = [Node {rootLabel = Right "connection", subForest = []}]}]},Node {rootLabel = Right "register", subForest = []},Node {rootLabel = Right "password-reset", subForest = [Node {rootLabel = Right "complete", subForest = []}]},Node {rootLabel = Right "password", subForest = []},Node {rootLabel = Right "login", subForest = []},Node {rootLabel = Right "email", subForest = []},Node {rootLabel = Right "approve", subForest = []},Node {rootLabel = Right "activate", subForest = []}]},Node {rootLabel = Right "properties-values", subForest = []},Node {rootLabel = Right "properties", subForest = [Node {rootLabel = Left ":key", subForest = []}]},Node {rootLabel = Right "password-reset", subForest = [Node {rootLabel = Right "complete", subForest = []},Node {rootLabel = Left ":key", subForest = []}]},Node {rootLabel = Right "onboarding", subForest = [Node {rootLabel = Right "v3", subForest = []}]},Node {rootLabel = Right "login", subForest = [Node {rootLabel = Right "send", subForest = []}]},Node {rootLabel = Right "i", subForest = [Node {rootLabel = Right "users", subForest = [Node {rootLabel = Right "revoke-identity", subForest = []},Node {rootLabel = Right "phone-prefixes", subForest = [Node {rootLabel = Left ":prefix", subForest = []}]},Node {rootLabel = Right "password-reset-code", subForest = []},Node {rootLabel = Right "login-code", subForest = []},Node {rootLabel = Right "connections-status", subForest = []},Node {rootLabel = Right "blacklist", subForest = []},Node {rootLabel = Right "activation-code", subForest = []},Node {rootLabel = Left ":uid", subForest = [Node {rootLabel = Right "sso-id", subForest = []},Node {rootLabel = Right "rich-info", subForest = []},Node {rootLabel = Right "managed-by", subForest = []},Node {rootLabel = Right "is-team-owner", subForest = [Node {rootLabel = Left ":tid", subForest = []}]},Node {rootLabel = Right "can-be-deleted", subForest = [Node {rootLabel = Left ":tid", subForest = []}]}]},Node {rootLabel = Left ":id", subForest = [Node {rootLabel = Right "status", subForest = []},Node {rootLabel = Right "reauthenticate", subForest = []},Node {rootLabel = Right "contacts", subForest = []},Node {rootLabel = Right "auto-connect", subForest = []}]}]},Node {rootLabel = Right "teams", subForest = [Node {rootLabel = Right "invitation-code", subForest = []},Node {rootLabel = Left ":tid", subForest = [Node {rootLabel = Right "unsuspend", subForest = []},Node {rootLabel = Right "suspend", subForest = []}]}]},Node {rootLabel = Right "status", subForest = []},Node {rootLabel = Right "sso-login", subForest = []},Node {rootLabel = Right "self", subForest = [Node {rootLabel = Right "email", subForest = []}]},Node {rootLabel = Right "provider", subForest = [Node {rootLabel = Right "activation-code", subForest = []}]},Node {rootLabel = Right "monitoring", subForest = []},Node {rootLabel = Right "index", subForest = [Node {rootLabel = Right "reindex", subForest = []},Node {rootLabel = Right "refresh", subForest = []}]},Node {rootLabel = Right "clients", subForest = [Node {rootLabel = Right "legalhold", subForest = [Node {rootLabel = Left ":uid", subForest = [Node {rootLabel = Right "request", subForest = []}]}]},Node {rootLabel = Left ":uid", subForest = []}]}]},Node {rootLabel = Right "delete", subForest = []},Node {rootLabel = Right "cookies", subForest = [Node {rootLabel = Right "remove", subForest = []}]},Node {rootLabel = Right "conversations", subForest = [Node {rootLabel = Left ":cnv", subForest = [Node {rootLabel = Right "bots", subForest = [Node {rootLabel = Left ":bot", subForest = []}]}]}]},Node {rootLabel = Right "connections", subForest = [Node {rootLabel = Left ":id", subForest = []}]},Node {rootLabel = Right "clients", subForest = [Node {rootLabel = Left ":client", subForest = [Node {rootLabel = Right "prekeys", subForest = []}]}]},Node {rootLabel = Right "calls", subForest = [Node {rootLabel = Right "config", subForest = [Node {rootLabel = Right "v2", subForest = []}]}]},Node {rootLabel = Right "bot", subForest = [Node {rootLabel = Right "users", subForest = [Node {rootLabel = Right "prekeys", subForest = []},Node {rootLabel = Left ":uid", subForest = [Node {rootLabel = Right "clients", subForest = []}]}]},Node {rootLabel = Right "self", subForest = []},Node {rootLabel = Right "client", subForest = [Node {rootLabel = Right "prekeys", subForest = []}]}]},Node {rootLabel = Right "activate", subForest = [Node {rootLabel = Right "send", subForest = []}]},Node {rootLabel = Right "access", subForest = [Node {rootLabel = Right "logout", subForest = []}]}]
