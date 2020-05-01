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

-- * General comments
-- $ 
-- "Hyperion.Database.HasDB" provides typeclass 'HasDB' which describes environments that contain a
-- 'DatabaseConfig', which is extracted by 'Lens'' 'dbConfigLens'. 
--
-- This is used in the following way: if we have a monad @m@ that
--
-- 1. is an instance of 'MonadIO', i.e. embeds 'IO' actions,
-- 2. an instance of 'MonadReader', i.e. it carries an environment,
-- 3. this environment is an instance of 'HasDB',
--
-- then we can create @m@-actions using 'withConnection', i.e. 
-- 
-- > doStuffWithConnection :: Sql.Connection -> IO a
-- > ...
-- > do -- here we are in m monad
-- >   ...
-- >   result <- withConnection doStuffWithConnection
-- >   ... 
--
-- 'withConnection' uses "Data.Pool". See 'Data.Pool.withResource' for details.

-- * Documentation

-- | Database information datatype 
data DatabaseConfig = DatabaseConfig
  { dbPool      :: Pool.Pool Sql.Connection
  , dbProgramId :: ProgramId
  }

-- | 'HasDB' typeclass
class HasDB env where
  dbConfigLens :: Lens' env DatabaseConfig

instance HasDB DatabaseConfig where
  dbConfigLens = id

type Pool = Pool.Pool Sql.Connection

-- | Produces a default pool with connections to the SQLite DB in the given file
newDefaultPool :: FilePath -> IO (Pool.Pool Sql.Connection)
newDefaultPool dbPath = do
  let
    stripes = 1
    connectionTime = 5
    poolSize = 1
  Pool.createPool (Sql.open dbPath) Sql.close stripes connectionTime poolSize

-- | Extracts the connection pool from the environment of our monad, gets a 
-- connection and runs the supplied function with it
withConnection
  :: forall m env a . (MonadIO m, MonadReader env m, HasDB env)
  => (Sql.Connection -> IO a)
  -> m a
withConnection go = do
  pool <- views dbConfigLens dbPool
  liftIO $ Pool.withResource pool go

-- | Tries 'withConnection' until succeeds. Failure means that 'Sql.SQLError' is
-- thrown during execution of the function. Otherwise execution is deemed successful.
-- Tries at most 10 times. If last attempt is a failure, the last exception propagates
-- outside of 'withConnectionRetry'. Uses 'retryRepeated' internally.
withConnectionRetry
  :: forall m env a . (MonadIO m, MonadReader env m, HasDB env, MonadCatch m)
  => (Sql.Connection -> IO a)
  -> m a
withConnectionRetry =
  retryRepeated 10 (try @m @Sql.SQLError) . withConnection
