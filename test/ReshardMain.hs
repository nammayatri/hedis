{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Reproduces a reshard against a live cluster while commands flow, and
-- reports what the client did during it. Uses only the public API, so the
-- same test runs unchanged against older versions of the library.
--
-- Needs the docker cluster of hedis-test-cluster and the name of its
-- container in HEDIS_RESHARD_CONTAINER, e.g.
--
--     docker run -d --name hedis-cluster -e IP=0.0.0.0 -e INITIAL_PORT=30001 \
--         -p 30001-30006:30001-30006 grokzen/redis-cluster:7.0.10
--     HEDIS_RESHARD_CONTAINER=hedis-cluster cabal test hedis-test-reshard
--
-- Without that variable the suite passes without doing anything.
--
-- The pool is kept small and the worker count high so that node pools are
-- saturated, as they are in production during a reshard. With the shard map
-- refresh running under the map lock and waiting without limit for a pool
-- connection, one MOVED then stalls every command in the process; with the
-- refresh running outside the lock and bounded, it does not.
module Main (main) where

import Control.Concurrent
import qualified Control.Concurrent.Async as Async
import Control.Exception
import Control.Monad
import qualified Data.ByteString.Char8 as Char8
import Data.IORef
import qualified Data.List as L
import Data.Time.Clock (getCurrentTime, diffUTCTime, NominalDiffTime)
import System.Environment (lookupEnv, setEnv)
import System.Process (readProcess)
import qualified Test.Framework as Test
import qualified Test.Framework.Providers.HUnit as Test (testCase)
import Test.HUnit (assertBool)

import Database.Redis

main :: IO ()
main = do
    setEnv "REDIS_POOL_ACQUIRE_TIMEOUT" "0.5"
    container <- lookupEnv "HEDIS_RESHARD_CONTAINER"
    Test.defaultMain
        [ case container of
            Nothing -> Test.testCase "reshard: skipped (HEDIS_RESHARD_CONTAINER not set)" (return ())
            Just c -> testCommandsKeepFlowingDuringReshard c
        ]

workers, secondsOfLoad :: Int
workers = 40
secondsOfLoad = 12

testCommandsKeepFlowingDuringReshard :: String -> Test.Test
testCommandsKeepFlowingDuringReshard container = Test.testCase "reshard: commands keep flowing while slots migrate" $ do
    conn <- connectCluster defaultConnectInfo { connectPort = PortNumber 30001, connectMaxConnections = 2 }
    forM_ [0 .. 999 :: Int] $ \i -> runRedis conn (set (key i) "v")
    latencies <- newIORef []
    failures <- newIORef (0 :: Int)
    stop <- newIORef False
    let worker w = do
            let go i = do
                    halt <- readIORef stop
                    unless halt $ do
                        started <- getCurrentTime
                        r <- try (runRedis conn (get (key ((w * 7919 + i) `mod` 1000))) >>= evaluate)
                        elapsed <- (`diffUTCTime` started) <$> getCurrentTime
                        case r of
                            Right (Right _) -> return ()
                            Right (Left _) -> atomicModifyIORef' failures (\n -> (n + 1, ()))
                            Left (_ :: SomeException) -> atomicModifyIORef' failures (\n -> (n + 1, ()))
                        atomicModifyIORef' latencies (\ls -> (elapsed : ls, ()))
                        go (i + 1)
            go (0 :: Int)
    ws <- mapM (Async.async . worker) [1 .. workers]
    threadDelay 2000000
    -- Move a third of the slots from the first master to the second while the
    -- workers run. redis-cli --cluster reshard migrates slot by slot, answering
    -- MOVED and ASK to clients as it goes.
    (fromId, toId) <- masterIds container
    reshardStarted <- getCurrentTime
    _ <- readProcess "docker" ["exec", container, "redis-cli", "--cluster", "reshard", "127.0.0.1:30001", "--cluster-from", fromId, "--cluster-to", toId, "--cluster-slots", "1800", "--cluster-yes"] ""
    reshardTook <- (`diffUTCTime` reshardStarted) <$> getCurrentTime
    threadDelay (secondsOfLoad * 1000000 - 2000000)
    writeIORef stop True
    mapM_ Async.wait ws
    -- put the slots back so the suite is repeatable
    _ <- readProcess "docker" ["exec", container, "redis-cli", "--cluster", "reshard", "127.0.0.1:30001", "--cluster-from", toId, "--cluster-to", fromId, "--cluster-slots", "1800", "--cluster-yes"] ""
    ls <- L.sort <$> readIORef latencies
    nFail <- readIORef failures
    let n = length ls
        pct p = ls !! min (n - 1) (floor (p * fromIntegral n :: Double))
        over t = length (filter (> t) ls)
    putStrLn $ "reshard of 1800 slots took " ++ show reshardTook
    putStrLn $ "commands: " ++ show n ++ "  failed: " ++ show nFail
    putStrLn $ "latency p50 " ++ show (pct 0.5) ++ "  p99 " ++ show (pct 0.99) ++ "  max " ++ show (maximum ls)
    putStrLn $ "commands over 1s: " ++ show (over 1) ++ "  over 5s: " ++ show (over (5 :: NominalDiffTime))
    assertBool ("commands failed during the reshard: " ++ show nFail) (nFail == 0)
    assertBool ("commands stalled for more than 5s during the reshard: " ++ show (over 5)) (over 5 == 0)
  where
    key :: Int -> Char8.ByteString
    key i = Char8.pack ("hedis:reshard:" ++ show i)

-- Node ids of the masters serving slot 0 and slot 16383, i.e. the first and
-- the last master in the default layout.
masterIds :: String -> IO (String, String)
masterIds container = do
    nodes <- readProcess "docker" ["exec", container, "redis-cli", "-p", "30001", "cluster", "nodes"] ""
    -- line: <id> <ip:port@cport> <flags,comma,separated> <master> <ping> <pong> <epoch> <link> <slot ranges...>
    let masters = [ (idOf l, slotsOf l) | l <- lines nodes, isMaster l ]
        isMaster l = case words l of
            (_ : _ : flags : _) -> "master" `elem` splitOn ',' flags
            _ -> False
        idOf l = head (words l)
        slotsOf l = drop 8 (words l)
        owner s = case [ i | (i, slots) <- masters, any (covers s) slots ] of
            (i : _) -> i
            [] -> error ("no master owns slot " ++ show s ++ " in:\n" ++ nodes)
        splitOn c str = case break (== c) str of
            (a, _ : rest) -> a : splitOn c rest
            (a, []) -> [a]
        covers s range = case break (== '-') range of
            (a, '-' : b) -> read a <= s && s <= (read b :: Int)
            (a, _) -> read a == s
    return (owner 0, owner 16383)
