module Main (main) where

import qualified DaggerParserTest
import qualified DaggerParserPropTest
import qualified IntermediateCompilerTest
import qualified TypeCheckerTest

import Test.QuickCheck
import Test.Framework (defaultMain, testGroup, Test)

allTests :: [Test]
allTests =
    [ testGroup "parser tests" DaggerParserTest.tests
--  , testGroup "property-based parser tests" DaggerParserPropTest.tests
    , testGroup "intermediate tests" IntermediateCompilerTest.tests
    , testGroup "Type checker tests" TypeCheckerTest.tests
    ]

main :: IO ()
main = do
  quickCheck DaggerParserPropTest.prop_ppp_identity2
  defaultMain allTests
