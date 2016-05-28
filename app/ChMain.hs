{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}


module Main where

import Debug.Trace
import qualified  Data.List as L
import qualified  Data.Map as M
import            Control.Monad.IO.Class
import            Control.Monad.Logger
import            Control.Monad.Trans.State
import            Data.Traversable
import qualified  Data.Vault.Strict as V

import            Control.Distributed.Process (RemoteTable)
import            Control.Distributed.Process.Node (initRemoteTable)
import            Control.Distributed.Process.Closure (mkClosure, remotable)

import            System.Environment (getArgs)

import            Blast
import            Blast.Distributed.Rpc.CloudHaskell
import qualified  Blast.Runner.Simple as S

{-
expGenerator a = do
      r1 <- cstRdd [1..100000::Int]
      r2 <- smap r1 $ fun ((+) a)
      zero <- cstLocal 0
      sum2 <- slocalfold r2 (foldFun (+)) zero
      r3 <- smap r1 (closure sum2 (\s a -> a+s))
      sum3 <- slocalfold r3 (foldFun (+)) zero
      r4 <- smap r2 (closure sum3 (\s a -> a+s))
      sum4 <- slocalfold r4 (foldFun (+)) zero
      a' <- cstLocal (a+1)
      r <- sfrom ((,) <$$> a' <**> sum4)
      return r
-}


fib :: Int -> Int
fib 0 = 0
fib 1 = 1
fib 2 = 3
fib n = fib (n-1) + fib (n-2)


expGenerator (a::Int) = do
      r1 <- rcst [ 2| _ <- [1..10::Int]]
      r2 <- rmap (fun fib) r1
      zero <- lcst (0::Int)
      c1 <- lcst (0 ::Int)
      a2 <- rfold' (foldClosure c1 (const (+))) sum zero r2
      --a2 <- collect r2
--      a2 <- slocalfold r1 (foldFun (+)) zero
      one <- lcst (1::Int)
      ar2 <- collect r2
      a3 <- lfold' (*) one ar2
      a' <- lcst (a+1)
      r <- ((,) <$$> a' <**> a2)
      return r

reporting a b = do
  putStrLn "Reporting"
  print a
  print b
  putStrLn "End Reporting"
  return a


jobDesc = MkJobDesc True 0 expGenerator reporting (\x -> x>=3)
--jobDesc = MkJobDesc True 0 expGenerator (\x -> False)

slaveClosure = slaveProcess jobDesc

remotable ['slaveClosure]

rtable :: RemoteTable
rtable = __remoteTable initRemoteTable



main = do
  args <- getArgs
  runRpc rtable args jobDesc $(mkClosure 'slaveClosure) k
  where
  k a b = do
    print a
    print b
    print "=========="


rrec = do
  (a,b) <- runStdoutLoggingT $ runRec jobDesc
  print a
  print b


--runRec :: (MonadIO m, MonadLoggerIO m) => Bool -> (a -> StateT Int m (LocalExp (a, b))) -> a -> (a -> Bool) -> m (a, b)
rrec' = do
  (a,b) <- runStdoutLoggingT $ S.runRec jobDesc
  print a
  print "kk"
  print b

