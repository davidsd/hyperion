{-# LANGUAGE RankNTypes       #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TypeApplications #-}

module Hyperion.Database.HasDB where

import           Control.Lens           (Lens', views)
import           Control.Monad.Catch    (MonadCatch, try)
import           Control.Monad.IO.Class (MonadIO, liftIO)
import           Control.Monad.Reader   (MonadReader)
import qualified Data.Pool              as Pool
import qualified Database.SQLite.Simple as Sql
import           Hyperion.ProgramId     (ProgramId)
import           Hyperion.Util          (retryRepeated)
import           Prelude                hiding (lookup)

data DatabaseConfig = DatabaseConfig
  { dbPool      :: Pool.Pool Sql.Connection
  , dbProgramId :: ProgramId
  }

class HasDB env where
  dbConfigLens :: Lens' env DatabaseConfig

instance HasDB DatabaseConfig where
  dbConfigLens = id

type Pool = Pool.Pool Sql.Connection

newDefaultPool :: FilePath -> IO (Pool.Pool Sql.Connection)
newDefaultPool dbPath = do
  let
    stripes = 1
    connectionTime = 5
    poolSize = 1
  Pool.createPool (Sql.open dbPath) Sql.close stripes connectionTime poolSize

withConnection
  :: forall m env a . (MonadIO m, MonadReader env m, HasDB env)
  => (Sql.Connection -> IO a)
  -> m a
withConnection go = do
  pool <- views dbConfigLens dbPool
  liftIO $ Pool.withResource pool go

withConnectionRetry
  :: forall m env a . (MonadIO m, MonadReader env m, HasDB env, MonadCatch m)
  => (Sql.Connection -> IO a)
  -> m a
withConnectionRetry =
  retryRepeated 10 (try @m @Sql.SQLError) . withConnection
