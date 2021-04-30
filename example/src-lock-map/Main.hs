{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StaticPointers    #-}
{-# LANGUAGE MultiWayIf #-}

module Main where

import           Control.Applicative (many)
import qualified Data.Text           as Text
import           Hyperion
import qualified Hyperion.Log        as Log
import qualified Options.Applicative as Opts
import Control.Distributed.Process (Process, liftIO, getSelfPid, kill)
import qualified Hyperion.LockMap as LM
import Control.Concurrent (threadDelay)
import Control.Monad.Trans (lift)
import Control.Monad.Reader (local)

data HelloOptions = HelloOptions
  { names   :: [String]
  , workDir :: FilePath
  } deriving (Show)

objects :: [(Int, String)]
objects = [(5, "Hello"), (4, "Hello2")]

getGreeting :: String -> Process String
getGreeting name = do
  getMasterNodeId >>= Log.info "My remote context is "
  Log.info "Generating greeting for" name
  case name of
    "fail" -> LM.withLock (objects !! 0) $ do
      Log.info "Locked " (objects !! 0)
      liftIO Log.flush
      liftIO $ threadDelay $ 3*1000*1000
      fail "Planned failure"
    "kill" -> LM.withLock (objects !! 0) $ do
      Log.info "Locked " (objects !! 0)
      liftIO Log.flush
      liftIO $ threadDelay $ 3*1000*1000
      pid <- getSelfPid
      kill pid "Planned suicide"
    "lock1" -> do
      liftIO $ threadDelay $ 5*1000*1000
      LM.withLock (objects !! 0) $ do
        Log.info "Locked " (objects !! 0)
        liftIO Log.flush
        liftIO $ threadDelay $ 30*1000*1000
    "lock2" -> do
      liftIO $ threadDelay $ 5*1000*1000
      LM.withLock (objects !! 1) $ do
        Log.info "Locked " (objects !! 1)
        liftIO Log.flush
        liftIO $ threadDelay $ 30*1000*1000
    "lock12" -> LM.withLocks objects $ do
      Log.info "Locked " objects
      liftIO Log.flush
      liftIO $ threadDelay $ 30*1000*1000
    "lock12_" -> do
      liftIO $ threadDelay $ 40*1000*1000
      LM.withLocks objects $ do
        Log.info "Locked " objects
        liftIO Log.flush
        liftIO $ threadDelay $ 30*1000*1000
    _ -> return ()
  Log.text "Unlocked stuff"
  return $ "Hello " ++ name ++ "!"

getGreetings :: [String] -> Job [String]
getGreetings names' = local (setTaskCpus 1) $ do
  mapConcurrently remoteGetGreeting names'

-- | Run a Slurm job to compute a greeting
remoteGetGreeting :: String -> Job String
remoteGetGreeting = remoteClosure . ptrAp (static getGreeting) . cPure

-- | Run a Slurm job to compute a greeting
remoteGetGreetings :: [String] -> Cluster [String]
remoteGetGreetings = remoteClosureJob . ptrAp (static getGreetings) . cPure

-- | Compute greetings concurrently in separate Slurm jobs and print them
printGreetings :: HelloOptions -> Cluster ()
printGreetings options = local (setJobType (MPIJob 2 2)) $ do
  lift getMasterNodeId >>= Log.info "My remote context is "
  let
--    greetingsC = Concurrently (remoteGetGreetings (names options))
--    lockC :: Concurrently Cluster ([String] -> [String])
--    lockC = Concurrently $ do
--      liftIO $ threadDelay $ 10*1000*1000
--      lift $ LM.withLocks objects $ do
--        Log.info "Locked " objects
--        liftIO $ threadDelay $ 10*1000*1000
--      Log.info "Unlocked" objects
--      return id
--    go = lockC <*> greetingsC
--  greetings <- runConcurrently go
  greetings <- remoteGetGreetings (names options)
  mapM_ (Log.text . Text.pack) greetings

-- | Command-line options parser
helloOpts :: Opts.Parser HelloOptions
helloOpts = HelloOptions
  <$> many (Opts.option Opts.str (Opts.long "name"))
  <*> Opts.option Opts.str (Opts.long "workDir")

main :: IO ()
main = hyperionMain helloOpts (
  \o -> (defaultHyperionConfig . workDir $ o) {sshRunCommand = Just ("ssh", ["-f", "-o", "StrictHostKeyChecking no"])}
  ) printGreetings
