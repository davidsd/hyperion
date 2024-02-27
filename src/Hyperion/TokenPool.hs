module Hyperion.TokenPool where

import Control.Concurrent.STM      (atomically, check)
import Control.Concurrent.STM.TVar (TVar, modifyTVar, newTVarIO, readTVar)
import Control.Monad.Catch         (MonadMask, bracket)
import Control.Monad.IO.Class      (MonadIO, liftIO)

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

