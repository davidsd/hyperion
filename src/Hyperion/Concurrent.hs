{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}

module Hyperion.Concurrent where

import           Control.Applicative         (Alternative (..), liftA2)
import           Control.Concurrent
import           Control.Distributed.Process (Process, kill, liftIO, spawnLocal)
import           Control.Exception           (SomeException, throwIO)
import           Control.Monad               (forever)
import           Control.Monad.Catch         (catch, mask, onException)
import           Control.Monad.Reader        (ReaderT (..))
import           Data.Foldable               (sequenceA_)
import           Data.Semigroup              (Semigroup (..))

race :: Process a -> Process b -> Process (Either a b)
race left right = concurrently' left right collect
    where
      collect m = do
        e <- liftIO $ takeMVar m
        case e of
          Left ex -> liftIO $ throwIO ex
          Right r -> return r

concurrently :: Process a -> Process b -> Process (a,b)
concurrently left right = concurrently' left right (collect [])
    where collect [Left a, Right b] _ = return (a,b)
          collect [Right b, Left a] _ = return (a,b)
          collect xs m = do
            e <- liftIO $ takeMVar m
            case e of
              Left ex -> liftIO $ throwIO ex
              Right r -> collect (r:xs) m

concurrently' :: Process a -> Process b
              -> (MVar (Either SomeException (Either a b)) -> Process r)
              -> Process r
concurrently' left right collect = do
  done <- liftIO newEmptyMVar
  mask $ \restore -> do
    lid <- spawnLocal $ restore (left >>= liftIO . putMVar done . Right . Left)
                                   `catch` (liftIO . putMVar done . Left)
    rid <- spawnLocal $ restore (right >>= liftIO . putMVar done . Right . Right)
                                   `catch` (liftIO . putMVar done . Left)
    let stop = kill lid "process died" >> kill rid "process died"
    r <- restore (collect done) `onException` stop
    stop
    return r

newtype Concurrently m a = Concurrently { runConcurrently :: m a }

instance Functor m => Functor (Concurrently m) where
  fmap f (Concurrently m) = Concurrently (fmap f m)

instance Applicative (Concurrently (ReaderT r Process)) where
  pure = Concurrently . pure
  Concurrently f <*> Concurrently a =
    Concurrently $ uncurry ($) <$> mapReaderT2 concurrently f a

instance Alternative (Concurrently (ReaderT r Process)) where
  empty = Concurrently $ liftIO $ forever (threadDelay maxBound)
  Concurrently as <|> Concurrently bs =
    Concurrently $ either id id <$> mapReaderT2 race as bs

mapReaderT2 :: (m a -> n b -> o c) -> ReaderT r m a -> ReaderT r n b -> ReaderT r o c
mapReaderT2 mf (ReaderT ma) (ReaderT mb) =
  ReaderT $ \r -> mf (ma r) (mb r)

instance (Applicative (Concurrently m), Semigroup a) => Semigroup (Concurrently m a) where
  (<>) = liftA2 (<>)

instance (Applicative (Concurrently m), Semigroup a, Monoid a) => Monoid (Concurrently m a) where
  mempty = pure mempty
  mappend = (<>)

doConcurrently :: (Applicative (Concurrently m), Traversable t) => t (m a) -> m (t a)
doConcurrently = runConcurrently . sequenceA . fmap Concurrently

doConcurrently_ :: (Applicative (Concurrently m), Foldable t, Functor t) => t (m a) -> m ()
doConcurrently_ = runConcurrently . sequenceA_ . fmap Concurrently

mapConcurrently :: (Applicative (Concurrently m), Traversable t) => (a -> m b) -> t a -> m (t b)
mapConcurrently f = doConcurrently . fmap f

mapConcurrently_ :: (Applicative (Concurrently m), Foldable t, Functor t) => (a -> m b) -> t a -> m ()
mapConcurrently_ f = doConcurrently_ . fmap f

forConcurrently :: (Applicative (Concurrently m), Traversable t) => t a -> (a -> m b) -> m (t b)
forConcurrently = flip mapConcurrently

forConcurrently_ :: (Applicative (Concurrently m), Foldable t, Functor t) => t a -> (a -> m b) -> m ()
forConcurrently_ = flip mapConcurrently_

replicateConcurrently :: Applicative (Concurrently m) => Int -> m a -> m [a]
replicateConcurrently n = doConcurrently . replicate n

replicateConcurrently_ :: Applicative (Concurrently m) => Int -> m a -> m ()
replicateConcurrently_ n = doConcurrently_ . replicate n
