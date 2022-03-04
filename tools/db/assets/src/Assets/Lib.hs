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

module Assets.Lib where

import Brig.Data.Instances
import Cassandra as C
import Cassandra.Settings as C
import qualified Conduit
import Data.Aeson (Value (Bool), encode)
import Data.Conduit
import qualified Data.Conduit.Combinators as Conduit
import Data.Id (UserId)
import Imports
import qualified System.Logger as Log
import Wire.API.Asset (nilAssetKey)
import Wire.API.User

cHost :: String
cHost = "127.0.01"

cPort :: Int
cPort = 9042

cKeyspace :: C.Keyspace
cKeyspace = C.Keyspace "brig_test"

main :: IO ()
main = do
  putStrLn "starting to read users ..."
  logger <- initLogger
  client <- initCas logger
  process client
  putStrLn "done"
  where
    initLogger =
      Log.new
        . Log.setOutput Log.StdOut
        . Log.setFormat Nothing
        . Log.setBufSize 0
        $ Log.defSettings
    initCas l =
      C.init
        . C.setLogger (C.mkLogger l)
        . C.setContacts cHost []
        . C.setPortNumber (fromIntegral cPort)
        . C.setKeyspace cKeyspace
        . C.setProtocolVersion C.V4
        $ C.defSettings

type UserRow = (UserId, Maybe [Asset])

selectUsersAll :: C.PrepQuery C.R () UserRow
selectUsersAll = "SELECT id, assets FROM user"

readUsers :: ClientState -> ConduitM () [UserRow] IO ()
readUsers client =
  transPipe (runClient client) $
    paginateC selectUsersAll (paramsP LocalQuorum () 50) x5

process :: ClientState -> IO ()
process client =
  runConduit $
    readUsers client
      .| Conduit.concat
      .| Conduit.filter (findInvalidAssetKey . snd)
      .| Conduit.mapM_ print
  where
    findInvalidAssetKey :: Maybe [Asset] -> Bool
    findInvalidAssetKey Nothing = False
    findInvalidAssetKey (Just assets) =
      any (\a -> assetKey a == nilAssetKey) assets
