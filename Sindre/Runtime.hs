{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Sindre.Runtime
-- License     :  MIT-style (see LICENSE)
--
-- Stability   :  provisional
-- Portability :  portable
--
-- Definitions for the Sindre runtime environment.
--
-----------------------------------------------------------------------------
module Sindre.Runtime ( Sindre
                      , execSindre
                      , quitSindre
                      , MonadSindre(..)
                      , broadcast
                      , changed
                      , redraw
                      , fullRedraw
                      , MonadBackend(..)
                      , Object(..)
                      , ObjectM
                      , fieldSet
                      , fieldGet
                      , callMethod
                      , Widget(..)
                      , WidgetM
                      , draw
                      , compose
                      , recvEvent
                      , DataSlot(..)
                      , SindreEnv(..)
                      , newEnv
                      , globalVal
                      , setGlobal
                      , Execution
                      , execute
                      , execute_
                      , returnHere
                      , doReturn
                      , nextHere
                      , doNext
                      , ScopedExecution(..)
                      , setScope
                      , enterScope
                      , lexicalVal
                      , setLexical
                      , eventLoop
                      , EventHandler
                      , Mold(..)
                      )
    where

import Sindre.Parser(parseInteger)
import Sindre.Sindre
import Sindre.Util

import System.Exit

import Control.Applicative
import Control.Monad.Cont
import Control.Monad.Reader
import Control.Monad.State
import Data.Array
import Data.Maybe
import Data.Monoid
import Data.Sequence((|>), ViewL(..))
import Data.Traversable(traverse)
import qualified Data.IntMap as IM
import qualified Data.Set as S
import qualified Data.Sequence as Q

data DataSlot m = forall s . Widget m s => WidgetSlot s Constraints
                | forall s . Object m s => ObjectSlot s

type Frame = IM.IntMap Value

data Redraw = RedrawAll | RedrawSome (S.Set WidgetRef)

data SindreEnv m = SindreEnv {
      objects   :: Array ObjectNum (DataSlot m)
    , evtQueue  :: Q.Seq (EventSource, Event)
    , globals   :: IM.IntMap Value
    , execFrame :: Frame
    , rootVal   :: InitVal m
    , kbdFocus  :: WidgetRef
    , arguments :: Arguments
    , needsRedraw :: Redraw
  }

newEnv :: InitVal m -> WidgetRef -> Arguments -> SindreEnv m
newEnv root rootwr argv =
  SindreEnv { objects   = array (0, -1) []
            , evtQueue  = Q.empty
            , globals   = IM.empty
            , execFrame = IM.empty
            , kbdFocus  = rootwr
            , rootVal   = root
            , arguments = argv
            , needsRedraw = RedrawAll
            }

class (Monad m, Functor m, Applicative m) => MonadBackend m where
  type BackEvent m :: *
  type InitVal m :: *
  initDrawing :: (Maybe Value, WidgetRef) -> Sindre m (Sindre m ())
  getBackEvent :: Sindre m (Maybe (EventSource, Event))
  waitForBackEvent :: Sindre m (EventSource, Event)
  printVal :: String -> m ()

type QuitFun m = ExitCode -> Sindre m ()

newtype Sindre m a = Sindre (ReaderT (QuitFun m)
                             (StateT (SindreEnv m)
                              (ContT ExitCode m))
                             a)
  deriving (Functor, Monad, Applicative, MonadCont,
            MonadState (SindreEnv m), MonadReader (QuitFun m))

instance MonadTrans Sindre where
  lift = Sindre . lift . lift . lift

instance MonadIO m => MonadIO (Sindre m) where
  liftIO = Sindre . liftIO

instance Monoid (Sindre m ()) where
  mempty = return ()
  mappend = (>>)
  mconcat = sequence_

execSindre :: MonadBackend m => SindreEnv m -> Sindre m a -> m ExitCode
execSindre s (Sindre m) = runContT m' return
    where m' = callCC $ \c -> do
                 let quitc code =
                       Sindre $ lift $ lift $ c code
                 _ <- execStateT (runReaderT m quitc) s
                 return ExitSuccess

quitSindre :: MonadBackend m => ExitCode -> Sindre m ()
quitSindre code = ($ code) =<< ask

class (MonadBackend im, Monad (m im)) => MonadSindre im m where
  sindre :: Sindre im a -> m im a
  back :: im a -> m im a
  back = sindre . lift

instance MonadBackend im => MonadSindre im Sindre where
  sindre = id

newtype ObjectM o m a = ObjectM (ReaderT ObjectRef (StateT o (Sindre m)) a)
    deriving (Functor, Monad, Applicative, MonadState o, MonadReader ObjectRef)

instance MonadBackend im => MonadSindre im (ObjectM o) where
  sindre = ObjectM . lift . lift

runObjectM :: Object m o => ObjectM o m a -> ObjectRef -> o -> Sindre m (a, o)
runObjectM (ObjectM m) wr = runStateT (runReaderT m wr)

class MonadBackend m => Object m s where
  callMethodI :: Identifier -> [Value] -> ObjectM s m Value
  callMethodI m _ = fail $ "Unknown method '" ++ m ++ "'"
  fieldSetI   :: Identifier -> Value -> ObjectM s m Value
  fieldSetI f _ = fail $ "Unknown field '" ++ f ++ "'"
  fieldGetI   :: Identifier -> ObjectM s m Value
  fieldGetI f = fail $ "Unknown field '" ++ f ++ "'"
  recvBackEventI :: BackEvent m -> ObjectM s m ()
  recvBackEventI _ = return ()
  recvEventI    :: Event -> ObjectM s m ()
  recvEventI _ = return ()

instance (MonadIO m, MonadBackend m) => MonadIO (ObjectM o m) where
  liftIO = sindre . back . io

newtype WidgetM w m a = WidgetM (ObjectM w m a)
    deriving (Functor, Monad, Applicative, MonadState w,
              MonadReader WidgetRef)

instance MonadBackend im => MonadSindre im (WidgetM o) where
  sindre = WidgetM . sindre

runWidgetM :: Widget m w => WidgetM w m a -> WidgetRef -> w -> Sindre m (a, w)
runWidgetM (WidgetM m) = runObjectM m

class Object m s => Widget m s where
  composeI      :: WidgetM s m SpaceNeed
  drawI         :: Maybe Rectangle -> WidgetM s m SpaceUse

instance (MonadIO m, MonadBackend m) => MonadIO (WidgetM o m) where
  liftIO = sindre . back . io

popQueue :: Sindre m (Maybe (EventSource, Event))
popQueue = do queue <- gets evtQueue
              case Q.viewl queue of
                e :< queue' -> do modify $ \s -> s { evtQueue = queue' }
                                  return $ Just e
                EmptyL      -> return Nothing

getEvent :: MonadBackend m => Sindre m (Maybe (EventSource, Event))
getEvent = liftM2 mplus getBackEvent popQueue

waitForEvent :: MonadBackend m => Sindre m (EventSource, Event)
waitForEvent = liftM2 fromMaybe waitForBackEvent popQueue

broadcast :: MonadBackend im => String -> Event -> ObjectM o im ()
broadcast f e = do
  src <- flip FieldSrc f <$> ask
  sindre $ modify $ \s -> s { evtQueue = evtQueue s |> (src, e) }

changed :: MonadBackend im =>
           Identifier -> Value -> Value -> ObjectM o im ()
changed f old new = broadcast f $ NamedEvent "changed" [old, new]

redraw :: (MonadBackend im, Widget im s) => ObjectM s im ()
redraw = do r <- ask
            sindre $ modify $ \s ->
              s { needsRedraw = needsRedraw s `add` r }
    where add RedrawAll      _ = RedrawAll
          add (RedrawSome s) w = RedrawSome $ w `S.insert` s

fullRedraw :: MonadSindre im m => m im ()
fullRedraw = sindre $ modify $ \s ->
             case needsRedraw s of
               RedrawAll  -> s
               _          -> s { needsRedraw = RedrawAll }

globalVal :: MonadBackend m => IM.Key -> Sindre m Value
globalVal k = IM.findWithDefault falsity k <$> gets globals

setGlobal :: MonadBackend m => IM.Key -> Value -> Sindre m ()
setGlobal k v =
  modify $ \s ->
    s { globals = IM.insert k v $ globals s }

operateW :: MonadBackend m => WidgetRef ->
            (forall o . Widget m o => o -> Constraints -> Sindre m (a, o))
         -> Sindre m a
operateW (r,_,_) f = do
  objs <- gets objects
  (v, s') <- case (objs!r) of
               WidgetSlot s sz -> do (v, s') <- f s sz
                                     return (v, WidgetSlot s' sz)
               _            -> fail "Expected widget"
  modify $ \s -> s { objects = objects s // [(r, s')] }
  return v

operateO :: MonadBackend m => ObjectRef ->
            (forall o . Object m o => o -> Sindre m (a, o)) -> Sindre m a
operateO (r,_,_) f = do
  objs <- gets objects
  (v, s') <- case (objs!r) of
               WidgetSlot s sz -> do (v, s') <- f s
                                     return (v, WidgetSlot s' sz)
               ObjectSlot s -> do (v, s') <- f s
                                  return (v, ObjectSlot s')
  modify $ \s -> s { objects = objects s // [(r, s')] }
  return v

actionO :: MonadBackend m => ObjectRef ->
           (forall o . Object m o => ObjectM o m a) -> Sindre m a
actionO r f = operateO r $ runObjectM f r

callMethod :: MonadSindre im m =>
              ObjectRef -> Identifier -> [Value] -> m im Value
callMethod r m vs = sindre $ actionO r (callMethodI m vs)
fieldSet :: MonadSindre im m =>
            ObjectRef -> Identifier -> Value -> m im Value
fieldSet r f v = sindre $ actionO r $ do
                   old <- fieldGetI f
                   new <- fieldSetI f v
                   changed f old new
                   return new
fieldGet :: MonadSindre im m => ObjectRef -> Identifier -> m im Value
fieldGet r f = sindre $ actionO r (fieldGetI f)
recvBackEvent :: MonadSindre im m => WidgetRef -> BackEvent im -> m im ()
recvBackEvent r ev = sindre $ actionO r (recvBackEventI ev)
recvEvent :: MonadSindre im m => WidgetRef -> Event -> m im ()
recvEvent r ev = sindre $ actionO r (recvEventI ev)

compose :: MonadSindre im m => WidgetRef -> m im SpaceNeed
compose r = sindre $ operateW r $ \w sz -> do
  (need, w') <- runWidgetM composeI r w
  return (constrainNeed need sz, w')
draw :: MonadSindre im m =>
        WidgetRef -> Maybe Rectangle -> m im SpaceUse
draw r rect = sindre $ operateW r $ \w _ -> runWidgetM (drawI rect) r w

type Breaker m a = (Frame, a -> Execution m ())

data ExecutionEnv m = ExecutionEnv {
      execReturn :: Breaker m Value
    , execNext   :: Breaker m ()
  }

setBreak :: MonadBackend m =>
            (Breaker m a -> ExecutionEnv m -> ExecutionEnv m) 
         -> Execution m a -> Execution m a
setBreak f m = do
  frame <- sindre $ gets execFrame
  callCC $ flip local m . f . (,) frame

doBreak :: MonadBackend m =>
           (ExecutionEnv m -> Breaker m a) -> a -> Execution m ()
doBreak b x = do
  (frame, f) <- asks b
  sindre $ modify $ \s -> s { execFrame = frame }
  f x

returnHere :: MonadBackend m => Execution m Value -> Execution m Value
returnHere = setBreak (\breaker env -> env { execReturn = breaker })

doReturn :: MonadBackend m => Value -> Execution m ()
doReturn = doBreak execReturn

nextHere :: MonadBackend m => Execution m () -> Execution m ()
nextHere = setBreak (\breaker env -> env { execNext = breaker })

doNext :: MonadBackend m => Execution m ()
doNext = doBreak execNext ()

newtype Execution m a = Execution (ReaderT (ExecutionEnv m) (Sindre m) a)
    deriving (Functor, Monad, Applicative, MonadReader (ExecutionEnv m), MonadCont)

execute :: MonadBackend m => Execution m Value -> Sindre m Value
execute m = runReaderT m' env
    where env = ExecutionEnv {
                  execReturn = (IM.empty, fail "Nowhere to return to")
                , execNext   = (IM.empty, fail "Nowhere to go next")
               }
          Execution m' = returnHere m


execute_ :: MonadBackend m => Execution m a -> Sindre m ()
execute_ m = execute (m *> return (IntegerV 0)) >> return ()

instance MonadBackend im => MonadSindre im Execution where
  sindre = Execution . lift

data ScopedExecution m a = ScopedExecution (Execution m a)

setScope :: MonadBackend m => [Value] -> ScopedExecution m a -> Execution m a
setScope vs (ScopedExecution ex) =
  sindre (modify $ \s -> s { execFrame = m }) >> ex
    where m = IM.fromList $ zip [0..] vs

enterScope :: MonadBackend m => [Value] -> ScopedExecution m a -> Execution m a
enterScope vs se = do
  oldframe <- sindre $ gets execFrame
  setScope vs se <* sindre (modify $ \s -> s { execFrame = oldframe })

lexicalVal :: MonadBackend m => IM.Key -> Execution m Value
lexicalVal k = IM.findWithDefault falsity k <$> sindre (gets execFrame)

setLexical :: MonadBackend m => IM.Key -> Value -> Execution m ()
setLexical k v = sindre $ modify $ \s ->
  s { execFrame = IM.insert k v $ execFrame s }

type EventHandler m = (EventSource, Event) -> Execution m ()

eventLoop :: MonadBackend m => Maybe (Execution m Value) -> WidgetRef
          -> EventHandler m -> Sindre m ()
eventLoop e rootwr handler = do
  e' <- traverse execute e
  redrawRoot' <- initDrawing (e', rootwr)
  let redraw_ RedrawAll      = redrawRoot'
      redraw_ (RedrawSome s) = mapM_ (`draw` Nothing) $ S.toList s
  forever $ do
    process
    redraw_ =<< gets needsRedraw
    modify $ \s -> s { needsRedraw = RedrawSome S.empty }
    handle =<< waitForEvent
  where handle ev = execute $ nextHere (handler ev) >> return falsity
        process = do ev <- getEvent
                     case ev of
                       Just ev' -> handle ev' >> process
                       Nothing  -> return ()

class Mold a where
  mold :: Value -> Maybe a
  unmold :: a -> Value

instance Mold Value where
  mold = Just
  unmold = id

instance Mold String where
  mold = Just . show
  unmold = StringV

instance Mold Integer where
  mold (Reference (v', _, _)) = Just $ fi v'
  mold (IntegerV x) = Just x
  mold (StringV s) = parseInteger s
  mold _ = Nothing
  unmold = IntegerV

instance Mold Int where
  mold = liftM (fi :: Integer -> Int) . mold
  unmold = IntegerV . fi

instance Mold Bool where
  mold = Just . true
  unmold False = falsity
  unmold True = truth

instance Mold () where
  mold   _ = Just ()
  unmold _ = IntegerV 0

aligns :: [(String, (Align, Align))]
aligns = [ ("top",      (AlignCenter, AlignNeg))
         , ("topleft",  (AlignNeg, AlignNeg))
         , ("topright", (AlignPos, AlignNeg))
         , ("bot",      (AlignCenter, AlignPos))
         , ("botleft",  (AlignNeg, AlignPos))
         , ("botright", (AlignPos, AlignPos))
         , ("mid",      (AlignCenter, AlignCenter))
         , ("midleft",  (AlignNeg, AlignCenter))
         , ("midright", (AlignPos, AlignCenter))]

instance Mold (Align, Align) where
  mold s = mold s >>= flip lookup aligns
  unmold a = maybe (IntegerV 0) StringV $
             lookup a (map (uncurry $ flip (,)) aligns)
