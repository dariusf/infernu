{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE StandaloneDeriving #-}
module Infernu.Fix
       ( Fix(..)
       , fmapReplace
       , replaceFix
       , fixToList
       )
       where

import Infernu.Prelude

newtype Fix f = Fix { unFix :: f (Fix f) }

instance Show (f (Fix f)) => Show (Fix f) where
  show (Fix x) = "Fix (" ++ (show x) ++ ")"
deriving instance Eq (f (Fix f)) => Eq (Fix f)
deriving instance Ord (f (Fix f)) => Ord (Fix f)

fmapReplace :: (Functor f, Eq (f a)) => (f a -> f b -> a -> b) -> f a -> f b -> f a -> f b
fmapReplace recurse tsource tdest t =
  if t == tsource
  then tdest
  else fmap (recurse tsource tdest) t

replaceFix :: (Functor f, Eq (f (Fix f))) => f (Fix f) -> f (Fix f) -> Fix f -> Fix f
replaceFix tsource tdest (Fix t') = Fix $ fmapReplace replaceFix tsource tdest t'


-- | Flattens a fix-type to a list of all tree nodes
--
-- >>> fixToList $ (Fix $ TCons TArray [Fix $ TCons TArray [Fix $ TBody TNumber]])
-- [Fix (TCons TArray [Fix (TCons TArray [Fix (TBody TNumber)])]),Fix (TCons TArray [Fix (TBody TNumber)]),Fix (TBody TNumber)]
-- >>> fixToList $ (Fix $ TRow $ TRowProp "x" (TScheme [] $ Fix $ TBody TNumber) (TRowEnd Nothing))
-- [Fix (TRow (TRowProp "x" (TScheme {schemeVars = [], schemeType = Fix (TBody TNumber)}) (TRowEnd Nothing))),Fix (TBody TNumber)]
fixToList :: Foldable t => Fix t -> [Fix t]
fixToList (Fix t) = (Fix t) : (foldr (\t' b -> fixToList t' ++ b) [] t)
