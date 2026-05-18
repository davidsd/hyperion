module Hyperion.TokenPool
  ( TokenPool
  , newTokenPool
  , withToken
  , forConcurrentlyMaxThreads_
  , doConcurrentlyMaxThreads_
  , mapConcurrentlyMaxThreads_
  ) where

import Control.Concurrent.STM      (atomically, check)
import Control.Concurrent.STM.TVar (TVar, modifyTVar, newTVarIO, readTVar)
import Control.Monad.Catch         (MonadMask, bracket)
import Control.Monad.IO.Class      (MonadIO, liftIO)
import Hyperion.Concurrent         (Concurrently, doConcurrently_,
                                    forConcurrently_, mapConcurrently_)

-- | A 'TokenPool' keeps track of the number of resources of some
-- kind, represented by "tokens". 'TokenPool (Just var)' indicates a
-- limited number of tokens, and 'var' contains the number of
-- available tokens. When 'var' contains 0, processes wishing to use a
-- token must block until one becomes available (see
-- 'withToken'). 'TokenPool Nothing' represents an unlimited number of
-- tokens.
newtype TokenPool = TokenPool (Maybe (TVar Int))

-- | Create a new 'TokenPool' containing the given number of
-- tokens. 'Nothing' indicates an unlimited pool.
newTokenPool :: Maybe Int -> IO TokenPool
newTokenPool (Just n) = TokenPool . Just <$> newTVarIO n
newTokenPool Nothing  = pure $ TokenPool Nothing

-- | Remove a token from the pool, run the given process, and then
-- replace the token. If no token is initially available, block until
-- one becomes available.
withToken :: (MonadIO m, MonadMask m) => TokenPool -> m a -> m a
withToken (TokenPool Nothing) go = go
withToken (TokenPool (Just tokenVar)) go =
  bracket (liftIO getToken) (liftIO . replaceToken) (\_ -> go)
  where
    getToken = atomically $ do
      tokens <- readTVar tokenVar
      check (tokens > 0)
      modifyTVar tokenVar (subtract 1)
      return ()
    replaceToken _ =
      atomically $ modifyTVar tokenVar (+1)

-- | A version of 'forConcurrently' that uses a TokenPool to ensure
-- that no more than 'numThreads' run at once. If 'Nothing', the same
-- as 'forConcurrently'.
forConcurrentlyMaxThreads_
  :: (Applicative (Concurrently m), MonadIO m, MonadMask m, Foldable t, Functor t)
  => Maybe Int
  -> t a
  -> (a -> m b)
  -> m ()
forConcurrentlyMaxThreads_ numThreads xs go = do
  tokenPool <- liftIO $ newTokenPool numThreads
  forConcurrently_ xs $ \x ->
    withToken tokenPool (go x)

-- | Analog of forConcurrentlyMaxThreads_
doConcurrentlyMaxThreads_
  :: (Applicative (Concurrently m), MonadIO m, MonadMask m, Foldable t, Functor t)
  => Maybe Int
  -> t (m a)
  -> m ()
doConcurrentlyMaxThreads_ numThreads gos = do
  tokenPool <- liftIO $ newTokenPool numThreads
  doConcurrently_ (fmap (withToken tokenPool) gos)

-- | Analog of forConcurrentlyMaxThreads_
mapConcurrentlyMaxThreads_
  :: (Applicative (Concurrently m), MonadIO m, MonadMask m, Foldable t, Functor t)
  => Maybe Int
  -> (a -> m b)
  -> t a
  -> m ()
mapConcurrentlyMaxThreads_ numThreads f xs = do
  tokenPool <- liftIO $ newTokenPool numThreads
  mapConcurrently_ (withToken tokenPool . f) xs
