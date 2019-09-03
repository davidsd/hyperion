{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Hyperion.Database.KeyValMap where

import           Control.Lens                     (views)
import           Control.Monad.IO.Class           (MonadIO)
import           Control.Monad.Reader             (MonadReader)
import           Control.Monad.Catch              (MonadCatch)
import           Data.Aeson                       (FromJSON, ToJSON)
import qualified Data.Aeson                       as Aeson
import qualified Data.ByteString.Lazy             as LBS
import           Data.Text                        (Text)
import qualified Data.Text.Encoding               as T
import           Data.Time.Clock                  (UTCTime)
import           Data.Typeable                    (Typeable)
import qualified Database.SQLite.Simple           as Sql
import qualified Database.SQLite.Simple.FromField as Sql
import qualified Database.SQLite.Simple.Ok        as Sql
import qualified Database.SQLite.Simple.ToField   as Sql
import           Hyperion.Database.HasDB
import           Prelude                          hiding (lookup)

-- The database table for a KeyValMap can contain multiple entries
-- with the same key. In this case, the newest entry is the active
-- one. Older entries are always ignored. Thus, an update can be
-- achieved by inserting a new key val pair.

-- The reason for this choice is that newer programs should not modify
-- data associated with old programs. However, a new program may
-- lookup data from old programs. This convention allows one to change
-- the data that a new program sees without violating the above
-- constraint.

newtype KeyValMap a b = KeyValMap { kvMapName :: Text }

instance Sql.ToField (KeyValMap a b) where
  toField = Sql.toField . kvMapName

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

instance (Typeable a, FromJSON a) => Sql.FromField (JsonField a) where
  fromField f = case Sql.fromField f of
    Sql.Ok txt -> case Aeson.eitherDecode (LBS.fromStrict (T.encodeUtf8 txt)) of
      Left err     -> Sql.returnError Sql.ConversionFailed f err
      Right result -> Sql.Ok (JsonField result)
    Sql.Errors err -> Sql.Errors err

instance ToJSON a => Sql.ToField (JsonField a) where
  toField (JsonField a) = Sql.SQLText $ T.decodeUtf8 $ LBS.toStrict $ Aeson.encode a

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

memoizeWithMap
  :: (MonadIO m, MonadReader env m, HasDB env, MonadCatch m, ToJSON a, ToJSON b, Typeable b, FromJSON b)
  => KeyValMap a b
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
