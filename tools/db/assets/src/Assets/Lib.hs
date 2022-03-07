{-# LANGUAGE RecordWildCards #-}

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
import Control.Lens
import Data.Aeson (Value (Bool), encode)
import Data.Conduit
import qualified Data.Conduit.Combinators as Conduit
import Data.Id (UserId)
import Data.Semigroup ((<>))
import Data.Text.Strict.Lens
import Imports
import Options.Applicative
import qualified System.Logger as Log
import Wire.API.Asset (nilAssetKey)
import Wire.API.User

data Opts = Opts
  { cHost :: String,
    cPort :: Int,
    cKeyspace :: C.Keyspace
  }

sampleParser :: Parser Opts
sampleParser =
  Opts
    <$> strOption
      ( long "cassandra-host"
          <> short 'h'
          <> metavar "HOST"
          <> help "Cassandra Host"
          <> value "localhost"
          <> showDefault
      )
    <*> option
      auto
      ( long "cassandra-port"
          <> short 'p'
          <> metavar "PORT"
          <> help "Cassandra Port"
          <> value 9042
          <> showDefault
      )
    <*> ( C.Keyspace . view packed
            <$> strOption
              ( long "cassandra-keyspace"
                  <> metavar "STRING"
                  <> help "Cassandra Keyspace"
                  <> value "brig_test"
                  <> showDefault
              )
        )

main :: IO ()
main = do
  putStrLn "starting to read users ..."
  opts <- execParser (info (helper <*> sampleParser) desc)
  logger <- initLogger
  client <- initCas opts logger
  process client
  putStrLn "done"
  where
    initLogger =
      Log.new
        . Log.setOutput Log.StdOut
        . Log.setFormat Nothing
        . Log.setBufSize 0
        $ Log.defSettings
    initCas Opts {..} l =
      C.init
        . C.setLogger (C.mkLogger l)
        . C.setContacts cHost []
        . C.setPortNumber (fromIntegral cPort)
        . C.setKeyspace cKeyspace
        . C.setProtocolVersion C.V4
        $ C.defSettings
    desc =
      header "assets"
        <> progDesc "find invalid asset keys in cassandra brig"
        <> fullDesc

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
