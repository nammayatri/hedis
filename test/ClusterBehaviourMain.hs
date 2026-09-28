{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Behaviour of the cluster client under pool pressure, against a live
-- cluster. Expects the same cluster as hedis-test-cluster (any node on port
-- 30001), for example:
--
--     docker run -e IP=0.0.0.0 -e INITIAL_PORT=30001 -p 30001-30006:30001-30006 grokzen/redis-cluster:7.0.10
module Main (main) where

import Control.Concurrent
import qualified Control.Concurrent.Async as Async
import Control.Exception
import Data.Time.Clock (getCurrentTime, diffUTCTime)
import System.Environment (setEnv)
import qualified Test.Framework as Test
import qualified Test.Framework.Providers.HUnit as Test (testCase)
import Test.HUnit (assertBool)

import Database.Redis
import qualified Database.Redis.Cluster as Cluster

main :: IO ()
main = do
    -- Read once, on first use, by the pool acquire path.
    setEnv "REDIS_POOL_ACQUIRE_TIMEOUT" "0.2"
    Test.defaultMain
        [ testPoolAcquireTimeoutIsTerminal
        ]

-- A command that cannot get a connection to its node within the acquire
-- timeout must fail with PoolAcquireTimeoutException right then. It must not
-- be re-sent to a random node (which only answers MOVED), trigger a shard-map
-- refresh, and wait out a second acquire timeout on the same busy node.
testPoolAcquireTimeoutIsTerminal :: Test.Test
testPoolAcquireTimeoutIsTerminal = Test.testCase "a pool acquire timeout fails the command without retry or refresh" $ do
    conn <- connectCluster defaultConnectInfo { connectPort = PortNumber 30001, connectMaxConnections = 1 }
    _ <- runRedis conn (del ["hedis:acquire:list"])
    -- Occupy the only connection to the node that owns the key for 2 s.
    blocker <- Async.async $ runRedis conn (blpop ["hedis:acquire:list"] 2)
    threadDelay 100000
    started <- getCurrentTime
    result <- try (runRedis conn (get "hedis:acquire:list") >>= evaluate)
    elapsed <- (`diffUTCTime` started) <$> getCurrentTime
    _ <- Async.wait blocker
    case result of
        Left (e :: SomeException) -> case fromException e of
            Just (Cluster.PoolAcquireTimeoutException _) -> return ()
            Nothing -> assertBool ("expected PoolAcquireTimeoutException, got " ++ show e) False
        Right v -> assertBool ("expected PoolAcquireTimeoutException, got " ++ show v) False
    assertBool ("command took " ++ show elapsed ++ ", more than one acquire timeout") (elapsed < 0.35)
