{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Tests for the cluster client's concurrency helpers. These need no Redis
-- server; they exercise the refresh gate and the pool acquire path directly.
module Main (main) where

import Control.Concurrent
import Control.Concurrent.Async (async, wait)
import Control.Exception
import Control.Monad
import Data.IORef
import qualified Data.ByteString.Char8 as Char8
import qualified Test.Framework as Test
import qualified Test.Framework.Providers.HUnit as Test (testCase)
import Test.HUnit ((@?=), assertBool)
import Data.Pool (newPool, defaultPoolConfig, setNumStripes, withResource)
import Data.Time.Clock (getCurrentTime, diffUTCTime)
import qualified Data.HashMap.Strict as HM
import qualified Data.IntMap.Strict as IntMap
import Data.List (sort)
import System.Timeout (timeout)

import Data.Pool (takeResource)
import System.Environment (setEnv)

import qualified Database.Redis.Cluster as Cluster
import Database.Redis.Cluster (Node(..), NodeRole(..), Shard(..), ShardMap(..))
import Database.Redis.Connection (defaultClusterConnectInfo, refreshShardMapWithFetch, refreshShardMapWithNodeConn)

main :: IO ()
main = do
    -- Read once, on first use, by the pool acquire path; must be set before
    -- anything in the library touches a node pool.
    setEnv "REDIS_POOL_ACQUIRE_TIMEOUT" "0.2"
    Test.defaultMain
        [ testSingleFlightSharesOneRefresh
        , testSingleFlightRefreshesAgainAfterCompletion
        , testSingleFlightFailureDoesNotPoisonGate
        , testAcquireFailsFastWhenPoolExhausted
        , testAcquireTimeoutLeaksNoCapacity
        , testRefreshDoesNotBlockReaders
        , testConcurrentRefreshesShareOneFetch
        , testRefreshMergesNodePools
        , testRefreshGivesUpWhenNodePoolsAreExhausted
        ]

-- A CLUSTER SLOTS fetch needs a connection from a node pool. When every
-- connection of every candidate node is busy, the fetch must give up after
-- the acquire timeout rather than wait for a connection without limit.
testRefreshGivesUpWhenNodePoolsAreExhausted :: Test.Test
testRefreshGivesUpWhenNodePoolsAreExhausted = Test.testCase "refreshShardMapWithNodeConn: gives up when the node pools are exhausted" $ do
    -- The node's only connection stays busy for the whole test. Nothing ever
    -- uses it, so it need not be a real connection.
    pool <- newPool $ setNumStripes (Just 1) $ defaultPoolConfig (newIORef Nothing >>= \ref -> return (error "connection never used", ref)) (\_ -> return ()) 30 1
    _held <- takeResource pool
    let nodeConn = Cluster.NodeConnection pool "node-a"
    started <- getCurrentTime
    result <- timeout 2000000 $ try (refreshShardMapWithNodeConn (Just nodeConn) [nodeConn])
    elapsed <- (`diffUTCTime` started) <$> getCurrentTime
    case result of
        Nothing -> assertBool "refresh hung waiting for a node connection" False
        Just (Left (e :: SomeException)) -> case fromException e of
            Just (Cluster.PoolAcquireTimeoutException _) -> return ()
            Nothing -> assertBool ("expected PoolAcquireTimeoutException, got " ++ show e) False
        Just (Right _) -> assertBool "refresh succeeded without a connection" False
    assertBool ("refresh did not give up promptly: " ++ show elapsed) (elapsed < 1.5)

------------------------------------------------------------------------------
-- refreshShardMap
--

-- A shard map with one master per given node id. Node pools are created
-- lazily, so no connection is ever opened by these tests.
shardMapOf :: [String] -> ShardMap
shardMapOf ids = ShardMap $ IntMap.fromList $ zip [0 ..] $ map shardOf ids
  where
    shardOf nodeid = Shard (Node (Char8.pack nodeid) Master ("host-" ++ nodeid) 6379 Nothing) []

newClusterConnection :: ShardMap -> IO Cluster.Connection
newClusterConnection = Cluster.createClusterConnectionPools noConnect 1 30 []
  where
    noConnect host _ = throwIO $ userError $ "unexpected connection attempt to " ++ host

-- While the CLUSTER SLOTS fetch of a refresh is in flight, commands that
-- only need to read the current shard map must not wait for it.
testRefreshDoesNotBlockReaders :: Test.Test
testRefreshDoesNotBlockReaders = Test.testCase "refreshShardMap: readers are not blocked while a fetch is in flight" $ do
    conn@(Cluster.Connection shardNodeVar _ _) <- newClusterConnection (shardMapOf ["a"])
    release <- newEmptyMVar
    refresher <- async $ refreshShardMapWithFetch defaultClusterConnectInfo conn (takeMVar release >> return (shardMapOf ["a", "b"]))
    threadDelay 50000 -- let the refresh reach its fetch
    readDuringFetch <- timeout 1000000 (readMVar shardNodeVar)
    putMVar release ()
    _ <- wait refresher
    assertBool "readMVar on the shard map blocked while the fetch was in flight" (maybe False (const True) readDuringFetch)

-- Two refreshes requested while one fetch is in flight must result in one
-- fetch, and both callers must see its result.
testConcurrentRefreshesShareOneFetch :: Test.Test
testConcurrentRefreshesShareOneFetch = Test.testCase "refreshShardMap: concurrent refreshes share one fetch" $ do
    conn <- newClusterConnection (shardMapOf ["a"])
    fetches <- newIORef (0 :: Int)
    release <- newEmptyMVar
    let fetch = atomicModifyIORef' fetches (\n -> (n + 1, ())) >> takeMVar release >> return (shardMapOf ["a", "b"])
    r1 <- async $ refreshShardMapWithFetch defaultClusterConnectInfo conn fetch
    r2 <- async $ refreshShardMapWithFetch defaultClusterConnectInfo conn fetch
    threadDelay 100000
    putMVar release ()
    (ShardMap m1, _) <- wait r1
    (ShardMap m2, _) <- wait r2
    readIORef fetches >>= (@?= 1)
    IntMap.size m1 @?= 2
    IntMap.size m2 @?= 2

-- After a refresh the node map holds a pool for every node in the new shard
-- map, reusing the existing pool for nodes that were already known.
testRefreshMergesNodePools :: Test.Test
testRefreshMergesNodePools = Test.testCase "refreshShardMap: node pools are reused for known nodes and created for new ones" $ do
    conn@(Cluster.Connection shardNodeVar _ _) <- newClusterConnection (shardMapOf ["a", "b"])
    (_, before) <- readMVar shardNodeVar
    (_, after) <- refreshShardMapWithFetch defaultClusterConnectInfo conn (return (shardMapOf ["b", "c"]))
    sort (HM.keys after) @?= ["b", "c"]
    HM.lookup "b" after @?= HM.lookup "b" before
    (_, stored) <- readMVar shardNodeVar
    sort (HM.keys stored) @?= ["b", "c"]

------------------------------------------------------------------------------
-- withResourceTimedMicros
--

-- With every resource of the pool held elsewhere, a timed acquire must throw
-- PoolAcquireTimeoutException once the timeout elapses, not wait forever.
testAcquireFailsFastWhenPoolExhausted :: Test.Test
testAcquireFailsFastWhenPoolExhausted = Test.testCase "withResourceTimedMicros: throws PoolAcquireTimeoutException when the pool is exhausted" $ do
    pool <- newPool $ setNumStripes (Just 1) $ defaultPoolConfig (return ()) (\_ -> return ()) 30 1
    release <- newEmptyMVar
    holder <- async $ withResource pool $ \_ -> takeMVar release
    threadDelay 50000 -- let the holder take the only resource
    started <- getCurrentTime
    result <- try (Cluster.withResourceTimedMicros 200000 pool "test-pool" (\_ -> return ("acquired" :: String)))
    elapsed <- (`diffUTCTime` started) <$> getCurrentTime
    putMVar release ()
    wait holder
    case result of
        Left (Cluster.PoolAcquireTimeoutException _) -> return ()
        Right v -> assertBool ("expected PoolAcquireTimeoutException, got " ++ show v) False
    assertBool ("acquire did not fail promptly: " ++ show elapsed) (elapsed < 1)

-- After acquires have timed out, the pool must still hand out its resource
-- once it is released: a timeout must never lose the resource it raced.
testAcquireTimeoutLeaksNoCapacity :: Test.Test
testAcquireTimeoutLeaksNoCapacity = Test.testCase "withResourceTimedMicros: timed-out acquires leak no pool capacity" $ do
    created <- newIORef (0 :: Int)
    pool <- newPool $ setNumStripes (Just 1) $ defaultPoolConfig (atomicModifyIORef' created (\n -> (n + 1, ()))) (\_ -> return ()) 30 1
    release <- newEmptyMVar
    holder <- async $ withResource pool $ \_ -> takeMVar release
    threadDelay 50000
    replicateM_ 5 $ do
        r <- try (Cluster.withResourceTimedMicros 20000 pool "test-pool" (\_ -> return ()))
        case r of
            Left (Cluster.PoolAcquireTimeoutException _) -> return ()
            Right () -> assertBool "acquire should have timed out" False
    putMVar release ()
    wait holder
    started <- getCurrentTime
    Cluster.withResourceTimedMicros 200000 pool "test-pool" (\_ -> return ())
    elapsed <- (`diffUTCTime` started) <$> getCurrentTime
    assertBool ("acquire after release was slow: " ++ show elapsed) (elapsed < 0.1)
    readIORef created >>= (@?= 1)

------------------------------------------------------------------------------
-- singleFlight
--

-- Fifty callers hit the gate while one refresh is in flight. Exactly one
-- refresh must run; everyone else reuses its result.
testSingleFlightSharesOneRefresh :: Test.Test
testSingleFlightSharesOneRefresh = Test.testCase "singleFlight: concurrent callers share one refresh" $ do
    gate <- Cluster.newRefreshGate
    refreshes <- newIORef (0 :: Int)
    entered <- newIORef (0 :: Int)
    release <- newEmptyMVar
    current <- newIORef ("initial" :: String)
    let refresh = do
            atomicModifyIORef' refreshes (\n -> (n + 1, ()))
            takeMVar release
            writeIORef current "refreshed"
            return "refreshed"
        reuse = readIORef current
        caller = do
            atomicModifyIORef' entered (\n -> (n + 1, ()))
            Cluster.singleFlight gate reuse refresh
    callers <- replicateM 50 (async caller)
    waitUntil ((== 50) <$> readIORef entered)
    threadDelay 100000 -- let every caller reach the gate
    putMVar release ()
    results <- mapM wait callers
    readIORef refreshes >>= (@?= 1)
    results @?= replicate 50 "refreshed"

-- A caller that arrives after a refresh has completed has seen a fresh
-- problem, so it must get a fresh refresh, not the stale result.
testSingleFlightRefreshesAgainAfterCompletion :: Test.Test
testSingleFlightRefreshesAgainAfterCompletion = Test.testCase "singleFlight: a later caller refreshes again" $ do
    gate <- Cluster.newRefreshGate
    refreshes <- newIORef (0 :: Int)
    let refresh = atomicModifyIORef' refreshes (\n -> (n + 1, n + 1))
        reuse = readIORef refreshes
    r1 <- Cluster.singleFlight gate reuse refresh
    r2 <- Cluster.singleFlight gate reuse refresh
    (r1, r2) @?= (1, 2)

-- A refresh that throws must not leave the gate locked or make later callers
-- reuse a result that never existed.
testSingleFlightFailureDoesNotPoisonGate :: Test.Test
testSingleFlightFailureDoesNotPoisonGate = Test.testCase "singleFlight: a failed refresh does not poison the gate" $ do
    gate <- Cluster.newRefreshGate
    refreshes <- newIORef (0 :: Int)
    let failing = atomicModifyIORef' refreshes (\n -> (n + 1, ())) >> throwIO (userError "cluster slots failed") >> return "never"
        working = atomicModifyIORef' refreshes (\n -> (n + 1, ())) >> return "refreshed"
        reuse = return ("reused" :: String)
    r1 <- try (Cluster.singleFlight gate reuse failing)
    case r1 of
        Left (_ :: IOException) -> return ()
        Right v -> assertBool ("expected the failure to propagate, got " ++ show v) False
    r2 <- Cluster.singleFlight gate reuse working
    r2 @?= "refreshed"
    readIORef refreshes >>= (@?= 2)

------------------------------------------------------------------------------
-- helpers
--

waitUntil :: IO Bool -> IO ()
waitUntil cond = go (200 :: Int)
  where
    go 0 = assertBool "condition not reached in time" False
    go n = do
        ok <- cond
        unless ok $ threadDelay 10000 >> go (n - 1)
