{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE OverloadedStrings  #-}

module Hyperion.Database.KeyValMap where

import Control.Lens                     (views)
import Control.Monad.Catch              (MonadCatch)
import Control.Monad.IO.Class           (MonadIO)
import Control.Monad.Reader             (MonadReader)
import Data.Aeson                       (FromJSON, ToJSON)
import Data.Aeson                       qualified as Aeson
import Data.Binary                      (Binary)
import Data.ByteString.Lazy             qualified as LBS
import Data.Data                        (Typeable)
import Data.Text                        (Text)
import Data.Text.Encoding               qualified as T
import Data.Time.Clock                  (UTCTime)
import Database.SQLite.Simple           qualified as Sql
import Database.SQLite.Simple.FromField qualified as Sql
import Database.SQLite.Simple.Ok        qualified as Sql
import Database.SQLite.Simple.ToField   qualified as Sql
import GHC.Generics                     (Generic)
import Hyperion.Database.HasDB
import Prelude                          hiding (lookup)

-- * General comments
-- $
-- "Hyperion.Database.KeyValMap" provides various actions with Sqlite
-- DB using 'withConnection' from "Hyperion.Database.HasDB".
--
-- The DB contains entries for 'KeyValMap': given 'kvMapName' and a
-- key, DB can produce value or values for the key.  We think about
-- this as a map, i.e. there is a preferred value for each key for a
-- given 'KeyValMap', even if DB contains the key several times. This
-- is described below.
--
-- The keys and values are represented by JSON encoding of Haskell
-- values. "Data.Aeson" is used to perform encoding/decoding.  Thus,
-- the keys and the values should implement 'ToJSON'/'FromJSON'
-- appropriately.


-- * Convention on DB entries with the same key
-- $
-- The database table for a 'KeyValMap' can contain multiple entries
-- with the same key. In this case, the newest entry is the active
-- one. Older entries are always ignored. Thus, an update can be
-- achieved by inserting a new key val pair.
--
-- The reason for this choice is that newer programs should not modify
-- data associated with old programs. However, a new program may
-- lookup data from old programs. This convention allows one to change
-- the data that a new program sees without violating the above
-- constraint.


-- | Type for 'KeyValMap' holds the types of key and value, but only
-- contains 'kvMapName' the name of the map
newtype KeyValMap a b = KeyValMap { kvMapName :: Text }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Binary, FromJSON, ToJSON)

-- | 'KeyValMap' is an instance of 'ToField' in order to use with Sqlite
instance Sql.ToField (KeyValMap a b) where
  toField = Sql.toField . kvMapName

-- | 'setupKeyValTable' creates the table "hyperion_key_val" if it
-- doesn't yet exist.  This table will hold the map-key-val entries.
--
-- The entry format is @program_id, kv_map, key, val, created_at@.
-- These are the program id, map name, key, value, and timestamp,
-- respectively.
--
-- @program_id@ is not used in lookups
setupKeyValTable
  :: (MonadIO m, MonadReader env m, HasDB env, MonadCatch m)
  => m ()
setupKeyValTable = withConnectionRetry $ \conn -> do
  Sql.execute_ conn sql
  where
    sql =
      "create table if not exists hyperion_key_val \
      \( program_id text not null \
      \, kv_map text not null \
      \, key text not null \
      \, val text not null \
      \, created_at timestamp default current_timestamp not null \
      \)"

newtype JsonField a = JsonField a

-- | Make 'JsonField' an instance of 'FromField'. First turns the field into Text and then tries to decode JSON.
-- Returns 'Sql.Errors' or 'Sql.Ok' with the result.
instance (Typeable a, FromJSON a) => Sql.FromField (JsonField a) where
  fromField f = case Sql.fromField f of
    Sql.Ok txt -> case Aeson.eitherDecode (LBS.fromStrict (T.encodeUtf8 txt)) of
      Left err     -> Sql.returnError Sql.ConversionFailed f err
      Right result -> Sql.Ok (JsonField result)
    Sql.Errors err -> Sql.Errors err

-- | Make 'JsonField' an instance of 'ToField'.
instance ToJSON a => Sql.ToField (JsonField a) where
  toField (JsonField a) = Sql.SQLText $ T.decodeUtf8 $ LBS.toStrict $ Aeson.encode a

-- | Inserts an map-key-val entry into the database.
--
-- If fails, retries using 'withConnectionRetry'
insert
  :: (MonadIO m, MonadReader env m, HasDB env, MonadCatch m, ToJSON a, ToJSON b)
  => KeyValMap a b
  -> a
  -> b
  -> m ()
insert kvMap key val = do
  programId <- views dbConfigLens dbProgramId
  withConnectionRetry $ \conn -> Sql.execute conn sql
    ( programId
    , kvMap
    , JsonField key
    , JsonField val
    )
  where
    sql =
      "insert into hyperion_key_val(program_id, kv_map, key, val) \
      \values (?, ?, ?, ?)"

-- | Looks up a value in the database given the map name and the
-- key. Takes the most recent matching entry according to the
-- convention.
--
-- If fails, retries using 'withConnectionRetry'
lookup
  :: (MonadIO m, MonadReader env m, HasDB env, MonadCatch m, ToJSON a, Typeable b, FromJSON b)
  => KeyValMap a b
  -> a
  -> m (Maybe b)
lookup kvMap key = withConnectionRetry $ \conn -> do
  result <- Sql.query conn sql (kvMap, JsonField key)
  case result of
    []                         -> return Nothing
    Sql.Only (JsonField a) : _ -> return $ Just a
  where
    sql =
      "select val from hyperion_key_val \
      \where kv_map = ? and key = ? \
      \order by created_at desc \
      \limit 1"

-- | Returns the list of all kev-value pairs for a given map. Again
-- only keeps the latest version of the value according to the
-- convention.
--
-- If fails, retries using 'withConnectionRetry'
lookupAll
  :: (MonadIO m, MonadReader env m, HasDB env, MonadCatch m, Typeable a, FromJSON a, Typeable b, FromJSON b)
  => KeyValMap a b
  -> m [(a,b)]
lookupAll kvMap = withConnectionRetry $ \conn -> do
  result <- Sql.query conn sql (Sql.Only kvMap)
  return $ map (\(JsonField a, JsonField b, _ :: UTCTime) -> (a,b)) result
  where
    sql =
      "select key, val, max(created_at) from hyperion_key_val \
      \where kv_map = ? \
      \group by key \
      \order by created_at"

-- | Same as 'lookup' but with a default value provided
lookupDefault
  :: (MonadIO m, MonadReader env m, HasDB env, MonadCatch m, ToJSON a, Typeable b, FromJSON b)
  => KeyValMap a b
  -> b
  -> a
  -> m b
lookupDefault kvMap def key = lookup kvMap key >>= \case
  Just v -> return v
  Nothing -> return def

-- | This implements memoization using the DB.  Given a function, it
-- first tries to look up the function result in the DB and if no
-- result is available, runs the function and inserts the result into
-- the DB
memoizeWithMap
  :: (MonadIO m, MonadReader env m, HasDB env, MonadCatch m, ToJSON a, ToJSON b, Typeable b, FromJSON b)
  => KeyValMap a b -- ^ The 'KeyValMap' in which to memoize
  -> (a -> m b)
  -> a
  -> m b
memoizeWithMap kvMap f a = do
  lookup kvMap a >>= \case
    Just b -> return b
    Nothing -> do
      b <- f a
      insert kvMap a b
      return b
