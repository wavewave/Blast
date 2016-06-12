{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}


module Blast.Slave.Analyser
where

import Debug.Trace
import            Control.Bool (unlessM)
import            Control.DeepSeq
import            Control.Lens (set, view)
import            Control.Monad.Logger
import            Control.Monad.IO.Class
import            Control.Monad.Operational
import            Control.Monad.Trans.Either
import            Control.Monad.Trans.State
import            Data.Binary (Binary)
import qualified  Data.ByteString as BS
import qualified  Data.Map as M
import qualified  Data.Serialize as S
import qualified  Data.Text as T
import qualified  Data.Vault.Strict as V
import            GHC.Generics (Generic)

import            Blast.Types
import            Blast.Common.Analyser



data SExp (k::Kind) a where
  SRApply :: Int -> V.Key b -> ExpClosure SExp a b -> SExp 'Remote a -> SExp 'Remote b
  SRConst ::  (Chunkable a, S.Serialize a) => Int -> V.Key a -> a -> SExp 'Remote a
  SLConst :: Int -> V.Key a -> a -> SExp 'Local a
  SCollect :: (UnChunkable a, S.Serialize a) => Int -> V.Key a -> SExp 'Remote a -> SExp 'Local a
  SLApply :: Int -> V.Key b -> SExp 'Local (a -> b) -> SExp 'Local a -> SExp 'Local b




nextIndex :: (MonadIO m) => StateT Int m Int
nextIndex = do
  index <- get
  put (index+1)
  return index


instance (MonadIO m) => Builder (StateT Int m) SExp where
  makeRApply f a = do
    i <- nextIndex
    k <- liftIO V.newKey
    return $ SRApply i k f a
  makeRConst a = do
    i <- nextIndex
    k <- liftIO V.newKey
    return $ SRConst i k a
  makeLConst a = do
    i <- nextIndex
    k <- liftIO V.newKey
    return $ SLConst i k a
  makeCollect a = do
    i <- nextIndex
    k <- liftIO V.newKey
    return $ SCollect i k a
  makeLApply f a = do
    i <- nextIndex
    k <- liftIO V.newKey
    return $ SLApply i k f a



type Cacher = BS.ByteString -> V.Vault -> V.Vault
type CacherReader = V.Vault -> Maybe BS.ByteString
type UnCacher = V.Vault -> V.Vault
type IsCached = V.Vault -> Bool

data NodeTypeInfo =
  NtRMap RMapInfo
  |NtRConst RConstInfo
  |NtLExp LExpInfo
  |NtLExpNoCache

data RMapInfo = MkRMapInfo {
  _rmRemoteClosure :: RemoteClosureImpl
  , _rmUnCacher :: UnCacher
  , _rmCacheReader :: Maybe CacherReader
  }

data RConstInfo = MkRConstInfo {
  _rcstCacher :: Cacher
  , _rcstUnCacher :: UnCacher
  , _rcstCacheReader :: Maybe CacherReader
  }

data LExpInfo = MkLExpInfo {
  _lexpCacher :: Cacher
  , _lexpUnCacher :: UnCacher
  }

type InfoMap = GenericInfoMap NodeTypeInfo



getVal :: (Monad m) =>  CachedValType -> V.Vault -> V.Key a -> EitherT RemoteClosureResult m a
getVal cvt vault key =
  case V.lookup key vault of
  Just v -> right v
  Nothing -> left $ RemCsResCacheMiss cvt

getLocalVal :: (Monad m) =>  CachedValType -> V.Vault -> V.Key a -> EitherT RemoteClosureResult m a
getLocalVal cvt vault key  =
  case V.lookup key vault of
  Just v -> right v
  Nothing -> left $ RemCsResCacheMiss cvt

getRemoteClosure :: Int -> InfoMap -> RemoteClosureImpl
getRemoteClosure n m =
  case M.lookup n m of
    Just (GenericInfo _ (NtRMap (MkRMapInfo cs _ _)))   -> cs
    Nothing -> error ("Closure does not exist for node: " ++ show n)




makeLocalCacheInfo :: (S.Serialize a) => V.Key a -> LExpInfo
makeLocalCacheInfo key =
  MkLExpInfo (makeCacher key) (makeUnCacher key)
  where
  makeCacher :: (S.Serialize a) => V.Key a -> BS.ByteString -> V.Vault -> V.Vault
  makeCacher k bs vault =
    case S.decode bs of
    Left e -> error $ ("Cannot deserialize value: " ++ e)
    Right a -> V.insert k a vault

makeUnCacher :: V.Key a -> V.Vault -> V.Vault
makeUnCacher k vault = V.delete k vault

makeIsCached :: V.Key a -> V.Vault -> Bool
makeIsCached k vault =
    case V.lookup k vault of
    Just _ -> True
    Nothing -> False



mkRemoteClosure :: forall a b m . (MonadLoggerIO m) =>
  V.Key a -> V.Key b -> ExpClosure SExp a b -> StateT InfoMap m RemoteClosureImpl
mkRemoteClosure keya keyb (ExpClosure e f) = do
  analyseLocal e
  addLocalExpCacheM e
  let keyc = getLocalVaultKey e
  return $ wrapClosure keyc keya keyb f


wrapClosure :: forall a b c .
            V.Key c -> V.Key a -> V.Key b -> (c -> a -> IO b) -> RemoteClosureImpl
wrapClosure keyc keya keyb f =
    proc
    where
    proc vault = do
      r' <- runEitherT r
      return $ either (\l -> (l, vault)) id r'
      where
      r = do
        c <- getLocalVal CachedFreeVar vault keyc
        av <- getVal CachedArg vault keya
        brdd <- liftIO $ (f c) av
        let vault' = V.insert keyb brdd vault
        return (ExecRes, vault')



visitRApplyExp :: Int -> V.Key a -> RemoteClosureImpl -> InfoMap -> InfoMap
visitRApplyExp n key cs m =
  case M.lookup n m of
  Just (GenericInfo _ _) -> error ("RApply Node " ++ show n ++ " has already been visited")
  Nothing -> M.insert n (GenericInfo 0 (NtRMap (MkRMapInfo cs (makeUnCacher key) Nothing))) m
  where
  makeUnCacher :: V.Key a -> V.Vault -> V.Vault
  makeUnCacher k vault = V.delete k vault


visitRApplyExpM ::  forall a m. (MonadLoggerIO m) =>
              Int -> V.Key a  -> RemoteClosureImpl -> StateT InfoMap m ()
visitRApplyExpM n key cs = do
  $(logInfo) $ T.pack  ("Visiting RMap node: " ++ show n)
  m <- get
  put $ visitRApplyExp n key cs m




visitLocalExp :: Int -> InfoMap -> InfoMap
visitLocalExp n m =
  case M.lookup n m of
  Just (GenericInfo _ _ ) -> error ("Node " ++ show n ++ " has already been visited")
  Nothing -> M.insert n (GenericInfo 0 NtLExpNoCache) m



visitLocalExpM :: forall a m. (MonadLoggerIO m) => Int -> StateT InfoMap m ()
visitLocalExpM n = do
  $(logInfo) $ T.pack  ("Visiting local exp node: " ++ show n)
  m <- get
  put $ visitLocalExp n m


addLocalExpCache :: (S.Serialize a) => Int -> V.Key a -> InfoMap -> InfoMap
addLocalExpCache n key m =
  case M.lookup n m of
  Just (GenericInfo c NtLExpNoCache) -> M.insert n (GenericInfo c (NtLExp (MkLExpInfo (makeCacher key) (makeUnCacher key)))) m
  Nothing -> M.insert n (GenericInfo 0 (NtLExp (MkLExpInfo (makeCacher key) (makeUnCacher key)))) m
  Just (GenericInfo _ (NtLExp _)) -> m
  _ ->  error ("Node " ++ show n ++ " cannot add local exp cache")
  where
  makeCacher :: (S.Serialize a) => V.Key a -> BS.ByteString -> V.Vault -> V.Vault
  makeCacher k bs vault =
    case S.decode bs of
    Left e -> error $ ("Cannot deserialize value: " ++ e)
    Right a -> V.insert k a vault

addLocalExpCacheM :: forall a m. (MonadLoggerIO m, S.Serialize a) =>
  SExp 'Local a -> StateT InfoMap m ()
addLocalExpCacheM e = do
  let n = getLocalIndex e
  $(logInfo) $ T.pack  ("Adding cache to local exp node: " ++ show n)
  let key = getLocalVaultKey e
  m <- get
  put $ addLocalExpCache n key m

addRemoteExpCacheReader :: (S.Serialize a) => Int -> V.Key a -> InfoMap -> InfoMap
addRemoteExpCacheReader n key m =
  case M.lookup n m of
  Just (GenericInfo _ (NtRMap (MkRMapInfo _ _ (Just _)))) -> m
  Just (GenericInfo c (NtRMap (MkRMapInfo cs uncacher Nothing))) ->
    M.insert n (GenericInfo c (NtRMap (MkRMapInfo cs uncacher (Just $ makeCacheReader key)))) m
  Just (GenericInfo _ (NtRConst (MkRConstInfo _ _ (Just _)))) -> m
  Just (GenericInfo c (NtRConst (MkRConstInfo cacher uncacher Nothing))) ->
    trace ("oui") $ M.insert n (GenericInfo c (NtRConst (MkRConstInfo cacher uncacher (Just $ makeCacheReader key)))) m
  _ ->  error ("Node " ++ show n ++ " cannot add remote exp cache reader")
  where
  makeCacheReader :: (S.Serialize a) => V.Key a -> V.Vault -> Maybe BS.ByteString
  makeCacheReader key vault =
    case V.lookup key vault of
      Nothing -> Nothing
      Just b -> Just $ S.encode b


addRemoteExpCacheReaderM ::
  forall a m. (MonadLoggerIO m, S.Serialize a)
  => SExp 'Remote a -> StateT InfoMap m ()
addRemoteExpCacheReaderM e = do
  let n = getRemoteIndex e
  $(logInfo) $ T.pack  ("Adding cache reader to remote exp node: " ++ show n)
  let key = getRemoteVaultKey e
  m <- get
  put $ addRemoteExpCacheReader n key m



mkRemoteClosureM :: forall a b m . (MonadLoggerIO m) =>
  V.Key a -> V.Key b -> ExpClosure SExp a b -> StateT InfoMap m RemoteClosureImpl
mkRemoteClosureM keya keyb (ExpClosure e f) = do
  analyseLocal e
  addLocalExpCacheM e
  let keyc = getLocalVaultKey e
  return $ wrapClosureM keyc keya keyb f


wrapClosureM :: forall a b c .
            V.Key c -> V.Key a -> V.Key b -> (c -> a -> IO b) -> RemoteClosureImpl
wrapClosureM keyc keya keyb f =
    proc
    where
    proc vault = do
      r' <- runEitherT r
      return $ either (\l -> (l, vault)) id r'
      where
      r = do
        c <- getLocalVal CachedFreeVar vault keyc
        av <- getVal CachedArg vault keya
        brdd <- liftIO $ (f c) av
        let vault' = V.insert keyb brdd vault
        return (ExecRes, vault')


getRemoteIndex :: SExp 'Remote a -> Int
getRemoteIndex (SRApply i _ _ _) = i
getRemoteIndex (SRConst i _ _) = i

getRemoteVaultKey :: SExp 'Remote a -> V.Key a
getRemoteVaultKey (SRApply _ k _ _) = k
getRemoteVaultKey (SRConst _ k _) = k

getLocalIndex :: SExp 'Local a -> Int
getLocalIndex (SLConst i _ _) = i
getLocalIndex (SCollect i _ _) = i
getLocalIndex (SLApply i _ _ _) = i

getLocalVaultKey :: SExp 'Local a -> V.Key a
getLocalVaultKey (SLConst _ k _) = k
getLocalVaultKey (SCollect _ k _) = k
getLocalVaultKey (SLApply _ k _ _) = k


analyseRemote :: (MonadLoggerIO m) => SExp 'Remote a -> StateT InfoMap m ()
analyseRemote (SRApply n keyb cs@(ExpClosure ce _) a) =
  unlessM (wasVisitedM n) $ do
    analyseRemote a
    increaseRefM (getRemoteIndex a)
    analyseLocal ce
    addLocalExpCacheM ce
    increaseRefM (getLocalIndex ce)
    $(logInfo) $ T.pack ("create closure for RApply node " ++ show n)
    let keya = getRemoteVaultKey a
    rcs <- mkRemoteClosure keya keyb cs
    visitRApplyM n keyb rcs
  where
  visitRApplyM ::  forall a m. (MonadLoggerIO m) =>
                Int -> V.Key a  -> RemoteClosureImpl -> StateT InfoMap m ()
  visitRApplyM n key cs = do
    $(logInfo) $ T.pack  ("Visiting RMap node: " ++ show n)
    m <- get
    put $ visitRApply n key cs m

  visitRApply :: Int -> V.Key a -> RemoteClosureImpl -> InfoMap -> InfoMap
  visitRApply n key cs m =
    case M.lookup n m of
    Just (GenericInfo _ _) -> error ("RMap Node " ++ show n ++ " has already been visited")
    Nothing -> M.insert n (GenericInfo 0 (NtRMap (MkRMapInfo cs (makeUnCacher key) Nothing))) m
    where

    makeUnCacher :: V.Key a -> V.Vault -> V.Vault
    makeUnCacher k vault = V.delete k vault

analyseRemote (SRConst n key _) =
  unlessM (wasVisitedM n) $ visitRConstExpM n key
  where
  visitRConstExpM ::  forall a m. (MonadLoggerIO m, S.Serialize a) =>
                Int -> V.Key a  -> StateT InfoMap m ()
  visitRConstExpM n key = do
    $(logInfo) $ T.pack  ("Visiting RConst node: " ++ show n)
    m <- get
    put $ visitRConst n key m

  visitRConst :: (S.Serialize a) => Int -> V.Key a -> InfoMap -> InfoMap
  visitRConst n key  m =
    case M.lookup n m of
    Just (GenericInfo _ _) -> error ("RConst Node " ++ show n ++ " has already been visited")
    Nothing -> M.insert n (GenericInfo 0 (NtRConst (MkRConstInfo (makeCacher key) (makeUnCacher key) Nothing))) m
    where
    makeCacher :: (S.Serialize a) => V.Key a -> BS.ByteString -> V.Vault -> V.Vault
    makeCacher k bs vault =
      case S.decode bs of
      Left e -> error $ ("Cannot deserialize value: " ++ e)
      Right a -> V.insert k a vault

    makeUnCacher :: V.Key a -> V.Vault -> V.Vault
    makeUnCacher k vault = V.delete k vault



analyseLocal :: (MonadLoggerIO m) => SExp 'Local a -> StateT InfoMap m ()

analyseLocal(SLConst n _ _) =
  unlessM (wasVisitedM n) $ visitLocalExpM n

analyseLocal (SCollect n _ e) =
  unlessM (wasVisitedM n) $ do
    analyseRemote e
    addRemoteExpCacheReaderM e
    increaseRefM (getRemoteIndex e)
    visitLocalExpM n

analyseLocal (SLApply n _ f e) =
  unlessM (wasVisitedM n) $ do
    analyseLocal f
    analyseLocal e
    visitLocalExpM n








