{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}

{-| This module contains copies of several utilities from
"Control.Concurrent.Async" from the @async@ package, with 'IO'
replaced by 'Process'.
-}
module Hyperion.Concurrent where

import           Control.Applicative         (Alternative (..), liftA2)
import           Control.Concurrent
import           Control.Distributed.Process (Process, kill, liftIO, spawnLocal)
import           Control.Exception           (SomeException, throwIO)
import           Control.Monad               (forever)
import           Control.Monad.Catch         (catch, mask, onException)
import           Control.Monad.Reader        (ReaderT (..))
import           Data.Foldable               (sequenceA_)


-- | Runs the two 'Process'es concurrently and returns the first available result,
-- 'kill'ing the unfinished process. If any of the processes throw an exception, 
-- the processes are 'kill'ed and the exception is propagated out of 'race'.
race :: Process a -> Process b -> Process (Either a b)
race left right = concurrently' left right collect
    where
      collect m = do
        e <- liftIO $ takeMVar m
        case e of
          Left ex -> liftIO $ throwIO ex
          Right r -> return r

-- | Runs the two 'Process'es concurrently and returns both results. If any of the 
-- processes throw an exception, the processes are 'kill'ed and the 
-- exception is propagated out of 'concurrently'.
concurrently :: Process a -> Process b -> Process (a,b)
concurrently left right = concurrently' left right (collect [])
    where collect [Left a, Right b] _ = return (a,b)
          collect [Right b, Left a] _ = return (a,b)
          collect xs m = do
            e <- liftIO $ takeMVar m
            case e of
              Left ex -> liftIO $ throwIO ex
              Right r -> collect (r:xs) m

-- | Runs two 'Process'es concurrently in two new threads. Each process will 
-- compute the result  and 'putMVar' it into an 'MVar'. The user-supplied 
-- continuation is applied to this 'MVar' concurrently with the two threads. 
-- When the continuation returns a result, the new threads are 'kill'ed and the
-- result is returned from 'concurrently''. If a thread fails, the 'MVar' is 
-- filled with 'Left' 'SomeException'. 
--
-- Note that the continutation can inspect the results of both threads by emptying
-- the 'MVar' when appropriate.
--
-- TODO: This code was originally copied from the
-- "Control.Concurrent.Async" module, with 'forkIO' replaced by
-- 'spawnLocal'. As of @async-2.1@, the code for this function has
-- changed. Have a look and figure out why, and whether the changes
-- should be ported here?
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

-- * 'Concurrently' type
-- $ 
-- @'Concurrently' m a@ represents a computation of type @m a@ that
-- can be run concurrently with other 'Concurrently'-type
-- computations. It is essentially a copy of the 'Concurrently'
-- applicative from "Control.Concurrent.Async", with 'IO' replaced by
-- 'Process'.
--
-- 'Concurrently' is an instance of several type classes (see below), but
-- most notable are the instances of 'Applicative' and 'Alternative'. 
-- The instances we define are for @'Concurrently' ('ReaderT' r 'Process')@, 
-- which in practice means @'Concurrently' 'Hyperion.Cluster.Cluster'@ and 
-- @'Concurrently' 'Hyperion.Job.Job'@.
--
-- = 'Applicative' instance
-- 
-- The 'Applicative' instance defines for @f :: 'Concurrently' m (a->b)@ and
-- @x :: 'Concurrently' m a@ computations
--
-- > f <*> x
--
-- to be the 'Concurrently m b' computation which is peformed as follows:
-- first, @f@ and @x@ are computed concurrently using 'concurrently', yielding values of the types
-- @a->b@ and @a@. Then these values are combined in the obvious way into a value
-- of type @b@. The implementation of @'pure' x@ is simply the computation which
-- returns @x@.
--
-- In this way, we can define, for example,
--
-- > doConcurrently' :: [ Concurrently m a ] -> Concurrently m [a]
-- > doConcurrenlty' [] = pure []
-- > doConcurrenlty' (x:xs) = pure (:) <*> x <*> doConcurrently' xs
--
-- which takes a list of computations and returns a computation that performs 
-- these computations concurrently and combines their results into a list. 
-- 
-- This definition of 'doConcurrently'' works in the following way. The first line
-- is the base for our recursive definition -- an empty list is a trivial computation.
-- The second line will first compute @'pure' (:)@ -- this is a rather trivial
-- concurrent computation that returns the function @'(:)'@. We combine this 
-- calcuation with @x@ using '<*>', which makes it into a calculation that computes
-- the function @(:) x'@, i.e. the function that prepends @x'@ to a list. Here 
-- @x'@ is the result of the calculation @x@. Then we combine this calculation
-- with @doConcurrently' xs@, which means that we compute @(:) x'@ concurrently
-- with @doConcurrently' xs@, and then combine the results. The result of 
-- @doConcurrently' xs@ will be a list of values, and we prepend @x'@ to it.
-- Recursing into @doConcurrently' xs@ we see that @doConcurrently'@ indeed works
-- by taking a list of computations, performing the calcuations concurrently, and
-- returning the list of results. 
--
-- We can also define a more convenient function 'doConcurrently' as follows
-- 
-- > doConcurrently :: [ m a ] -> m [a]
-- > doConcurrently xs = runConcurrently $ doConcurrently' $ map Concurrently xs
--
-- which works by dressing @m a@ in the list in 'Concurrently', performing 
-- @doConcurrently'@ and then finally removing the 'Concurrently' constructor using
-- 'runConcurrently'. The actual definition of 'doConcurrently' is more general,
-- so that it works on any 'Traversable' instance, not just on lists.
--
-- = 'Alternative' instance
-- $
-- The 'Alternative' instance of 'Concurrenlty' is similar, except it uses 
-- 'race' instead of 'concurrenlty'. Specifically,
--
-- > a <|> b
-- 
-- performs the computations @a@ and @b@ concurrently and returns the result of
-- whichever finishes earlier, using 'race'. The 'empty' implementation is a 
-- computation which never returns. In particular, 
--
-- > empty <|> empty
--
-- never returns (so is the same as 'empty', to some extent). We can do, for example
-- 
-- > asum [ x, y, z ]
--
-- which will run @x@, @y@, and @z@ concurrently and return the first returned 
-- result, 'kill'ing the unfinished computations.

newtype Concurrently m a = Concurrently { runConcurrently :: m a }

instance Functor m => Functor (Concurrently m) where
  fmap f (Concurrently m) = Concurrently (fmap f m)

instance Applicative (Concurrently Process) where
  pure = Concurrently . pure
  Concurrently f <*> Concurrently a =
    Concurrently $ uncurry ($) <$> concurrently f a

instance Alternative (Concurrently Process) where
  empty = Concurrently $ liftIO $ forever (threadDelay maxBound)
  Concurrently as <|> Concurrently bs =
    Concurrently $ either id id <$> race as bs

instance (Functor m, Applicative (Concurrently m)) => Applicative (Concurrently (ReaderT r m)) where
  pure = Concurrently . ReaderT . const . runConcurrently . pure
  Concurrently (ReaderT f) <*> Concurrently (ReaderT a) =
    Concurrently $ ReaderT $ \r -> runConcurrently $ Concurrently (f r) <*> Concurrently (a r)

instance (Functor m, Alternative (Concurrently m)) => Alternative (Concurrently (ReaderT r m)) where
  empty = Concurrently $ ReaderT $ const $ runConcurrently empty
  Concurrently (ReaderT as) <|> Concurrently (ReaderT bs) =
    Concurrently $ ReaderT $ \r -> runConcurrently $ Concurrently (as r) <|> Concurrently (bs r)

instance (Applicative (Concurrently m), Semigroup a) => Semigroup (Concurrently m a) where
  (<>) = liftA2 (<>)

instance (Applicative (Concurrently m), Monoid a) => Monoid (Concurrently m a) where
  mempty = pure mempty
  mappend = (<>)

-- * Utility functions using 'Applicative' instance of 'Concurrently'
-- $

-- | Run several computations in a traversable structure concurrently and collect the results.
doConcurrently :: (Applicative (Concurrently m), Traversable t) => t (m a) -> m (t a)
doConcurrently = runConcurrently . sequenceA . fmap Concurrently

-- | Run several computations in a traversable structure concurrently and forget the results.
doConcurrently_ :: (Applicative (Concurrently m), Foldable t, Functor t) => t (m a) -> m ()
doConcurrently_ = runConcurrently . sequenceA_ . fmap Concurrently

-- | Concurrently map a function over a traversable structure.
mapConcurrently :: (Applicative (Concurrently m), Traversable t) => (a -> m b) -> t a -> m (t b)
mapConcurrently f = doConcurrently . fmap f

-- | Concurrently map a function over a traversable structure and forget the results.
mapConcurrently_ :: (Applicative (Concurrently m), Foldable t, Functor t) => (a -> m b) -> t a -> m ()
mapConcurrently_ f = doConcurrently_ . fmap f

-- | Flipped version of 'mapConcurrently'.
forConcurrently :: (Applicative (Concurrently m), Traversable t) => t a -> (a -> m b) -> m (t b)
forConcurrently = flip mapConcurrently

-- | Flipped version of 'mapConcurrently_'.
forConcurrently_ :: (Applicative (Concurrently m), Foldable t, Functor t) => t a -> (a -> m b) -> m ()
forConcurrently_ = flip mapConcurrently_

-- | Concurrently run @n@ copies of a computation and collect the results in a list.
replicateConcurrently :: Applicative (Concurrently m) => Int -> m a -> m [a]
replicateConcurrently n = doConcurrently . replicate n

-- | Concurrently run @n@ copies of a computation and forget the results.
replicateConcurrently_ :: Applicative (Concurrently m) => Int -> m a -> m ()
replicateConcurrently_ n = doConcurrently_ . replicate n
