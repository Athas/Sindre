-----------------------------------------------------------------------------
-- |
-- Module      :  Sindre.Util
-- License     :  MIT-style (see LICENSE)
--
-- Stability   :  stable
-- Portability :  portable
--
-- Various utility bits and pieces.
--
-----------------------------------------------------------------------------
module Sindre.Util
    ( io
    , fi
    , err
    , upcase
    , downcase
    , hsv2rgb
    , wrap
    , quote
    , clamp
    , mapAccumLM
    , ifM
    , divide
    ) where

import Control.Monad.Trans

import Data.Char

import System.IO

-- | Short-hand for 'liftIO'
io :: MonadIO m => IO a -> m a
io = liftIO

-- | Short-hand for 'fromIntegral'
fi :: (Integral a, Num b) => a -> b
fi = fromIntegral

-- | Short-hand for 'liftIO . hPutStrLn stderr'
err :: MonadIO m => String -> m ()
err = io . hPutStrLn stderr

-- | Short-hand for 'map toUpper'
upcase :: String -> String
upcase = map toUpper

-- | Short-hand for 'map toLower'
downcase :: String -> String
downcase = map toLower

-- | Conversion scheme as in http://en.wikipedia.org/wiki/HSV_color_space
hsv2rgb :: Fractional a => (Integer,a,a) -> (a,a,a)
hsv2rgb (h,s,v) =
    let hi = div h 60 `mod` 6 :: Integer
        f = fi h/60 - fi hi :: Fractional a => a
        q = v * (1-f)
        p = v * (1-s)
        t = v * (1-(1-f)*s)
    in case hi of
         0 -> (v,t,p)
         1 -> (q,v,p)
         2 -> (p,v,t)
         3 -> (p,q,v)
         4 -> (t,p,v)
         5 -> (v,p,q)
         _ -> error "The world is ending. x mod a >= a."

-- | Prepend and append first argument to second argument.
wrap :: String -> String -> String
wrap x y = x ++ y ++ x

-- | Put double quotes around the given string.
quote :: String -> String
quote = wrap "\""

-- | Bound a value by minimum and maximum values.
clamp :: Ord a => a -> a -> a -> a
clamp lower x upper = min upper $ max lower x

-- | The 'mapAccumLM' function behaves like a combination of 'mapM' and
-- 'foldlM'; it applies a monadic function to each element of a list,
-- passing an accumulating parameter from left to right, and returning
-- a final value of this accumulator together with the new list.
mapAccumLM :: Monad m => (acc -> x -> m (acc, y))
           -> acc
           -> [x]
           -> m (acc, [y])
mapAccumLM _ s []     = return (s, [])
mapAccumLM f s (x:xs) = do
  (s', y ) <- f s x
  (s'',ys) <- mapAccumLM f s' xs
  return (s'',y:ys)

-- | Like 'when', but with two branches.  A lifted @if@.
ifM :: Monad m => m Bool -> m a -> m a -> m a
ifM p t e = do b <- p
               if b then t else e

-- | @x `divide` n@ splits the interval @[0..x]@ into @n@
-- non-overlapping chunks that together form the entire interval.
-- For example:
-- 
-- >>> 10 `divide` 3
-- [3,3,4]
divide :: Integral a => a -> a -> [a]
divide total n = map (const c) [0..n-2] ++ [c+r]
  where (c,r) = total `quotRem` n
