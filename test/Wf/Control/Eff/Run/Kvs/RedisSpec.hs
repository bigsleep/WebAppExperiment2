{-# LANGUAGE OverloadedStrings, TypeOperators, FlexibleContexts, TypeFamilies #-}
module Wf.Control.Eff.Run.Kvs.RedisSpec
( kvsRedisSpec
) where

import Control.Eff (Eff, VE(..), (:>), Member, SetMember, admin, handleRelay)
import Control.Eff.Lift (Lift, runLift)
import Wf.Control.Eff.Logger (LogLevel(..), runLoggerStdIO)
import Control.Eff.Exception (runExc)
import qualified Wf.Control.Eff.Kvs as Kvs (Kvs(..), get, set, setWithTtl, delete, exists, ttl, KeyType)

import Control.Exception (SomeException)
import Control.Concurrent (threadDelay)

import Data.Either (isLeft, isRight, either)
import qualified Database.Redis as Redis (get, set, setex, del, ConnectInfo(..), defaultConnectInfo, PortID(..), connect, runRedis, Status(..))
import qualified Data.ByteString as B (ByteString)
import qualified Data.ByteString.Char8 as B (pack)
import qualified Data.ByteString.Lazy as L (ByteString, fromStrict, toStrict)
import qualified Data.ByteString.Lazy.Char8 as L (pack)

import Wf.Application.Logger (Logger)
import Wf.Control.Eff.Run.Kvs.Redis (runKvsRedis)
import Wf.Application.Exception (Exception)

import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import qualified Test.Hspec.QuickCheck as Q
import qualified Test.QuickCheck.Property as Q


type instance Kvs.KeyType () = B.ByteString


kvsRedisSpec :: Spec
kvsRedisSpec = do
    setSpec
    setWithTtlSpec
    getSpec
    deleteSpec
    existsSpec
    ttlSpec


testConnectInfo :: Redis.ConnectInfo
testConnectInfo = Redis.defaultConnectInfo { Redis.connectDatabase = 15 }


setSpec :: Spec
setSpec = do
    Q.prop "kvs-redis set" $
        \val -> Q.ioProperty $ do
            let key = "key1"
            let code = Kvs.set () key (L.pack val)
            r <- runTest code
            shouldSatisfy r isRight
            con <- Redis.connect testConnectInfo
            x <- Redis.runRedis con $ Redis.get key
            let message = "expected: " ++ show val ++ " result: " ++ show x
            return $ if (Right . Just . B.pack $ val) == x
                        then Q.succeeded
                        else Q.failed { Q.reason = message}


setWithTtlSpec :: Spec
setWithTtlSpec = describe "kvs-redis setWithTtl" $
    it "should store value within a time to live" $ do
        let key = "key2"
        let val = "hello world"
        let ttl = 1
        let code = Kvs.setWithTtl () key (L.pack val) ttl
        Right () <- runTest code
        con <- Redis.connect testConnectInfo
        x <- Redis.runRedis con $ Redis.get key
        x `shouldBe` (Right . Just . B.pack $ val)
        threadDelay 1002000
        y <- Redis.runRedis con $ Redis.get key
        y `shouldBe` Right Nothing


getSpec :: Spec
getSpec = do
    Q.prop "kvs-redis get" $
        \val -> Q.ioProperty $ do
            let key = "key3"
            con <- Redis.connect testConnectInfo
            Redis.runRedis con $ Redis.set key (B.pack val)
            let code = Kvs.get () key
            (Right x) <- runTest code
            let message = "expected: " ++ show val ++ " result: " ++ show x
            let result = if (Just . L.pack $ val) == x
                            then Q.succeeded
                            else Q.failed { Q.reason = message }
            return result

    Q.prop "kvs-redis get nothing" $
        Q.ioProperty $ do
            let key = "key4" :: B.ByteString
            con <- Redis.connect testConnectInfo
            Redis.runRedis con $ Redis.del [key]
            let code = Kvs.get () key
            (Right x) <- runTest code
            let message = "expected: Nothing result: " ++ show x
            let result = if Nothing == (x :: Maybe L.ByteString)
                            then Q.succeeded
                            else Q.failed { Q.reason = message }
            return result


deleteSpec :: Spec
deleteSpec = describe "kvs-redis delete" $
    it "should delete" $ do
        let key = "key5"
        let val = "hoge"
        con <- Redis.connect testConnectInfo
        Redis.runRedis con $ Redis.set key (B.pack val)
        let code = Kvs.delete () key
        r <- runTest code
        r `shouldBe` Right True
        x <- Redis.runRedis con $ Redis.get key
        x `shouldBe` Right Nothing

existsSpec :: Spec
existsSpec = describe "kvs-redis exists" $ do
    it "should return true if key exists" $ do
        let key = "key6"
        let val = "aaa"
        con <- Redis.connect testConnectInfo
        Redis.runRedis con $ Redis.set key (B.pack val)
        let code = Kvs.exists () key
        r <- runTest code
        r `shouldBe` Right True

    it "should return False if key dose not exist" $ do
        let key = "key6"
        con <- Redis.connect testConnectInfo
        Redis.runRedis con $ Redis.del [key]
        let code = Kvs.exists () key
        r <- runTest code
        r `shouldBe` Right False

ttlSpec :: Spec
ttlSpec = describe "kvs-redis ttl" $ do
    let key = "key7"
    let ttl = 60

    it "should return time to live" $ do
        con <- Redis.connect testConnectInfo
        Redis.runRedis con $ Redis.setex key ttl "hello"
        let code = Kvs.ttl () key
        Right (Just r) <- runTest code
        shouldSatisfy r (> ttl - 1)

    it "should return Nothing if no ttl" $ do
        con <- Redis.connect testConnectInfo
        Redis.runRedis con $ Redis.set key "hello"
        let code = Kvs.ttl () key
        r <- runTest code
        r `shouldBe` Right Nothing


runTest :: Eff (Kvs.Kvs () :> Exception :> Logger :> Lift IO :> ()) a -> IO (Either String a)
runTest = (either (return . Left . show) (return . Right) =<<) . runLift . runLoggerStdIO DEBUG . runExc . runKvsRedis testConnectInfo

