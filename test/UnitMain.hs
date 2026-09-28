{-# LANGUAGE ScopedTypeVariables #-}
-- | Tests for the cluster client's concurrency helpers. These need no Redis
-- server; they exercise the refresh gate and the pool acquire path directly.
module Main (main) where

import Control.Concurrent
import Control.Concurrent.Async (async, wait)
import Control.Exception
import Control.Monad
import Data.IORef
import qualified Test.Framework as Test
import qualified Test.Framework.Providers.HUnit as Test (testCase)
import Test.HUnit ((@?=), assertBool)

import qualified Database.Redis.Cluster as Cluster

main :: IO ()
main = Test.defaultMain
    [ testSingleFlightSharesOneRefresh
    , testSingleFlightRefreshesAgainAfterCompletion
    , testSingleFlightFailureDoesNotPoisonGate
    ]

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
    current <- newIORef "initial"
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
        reuse = return "reused"
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
