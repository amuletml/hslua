{-
Copyright © 2017 Albert Krewinkel

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
-}
{-# LANGUAGE OverloadedStrings #-}
{-| Tests for lua -}
module Foreign.LuaTest (tests) where

import Prelude hiding (concat)

import Data.ByteString (ByteString)
import Data.Monoid ((<>))
import Foreign.Lua
import System.Mem (performMajorGC)
import Test.HsLua.Util (luaTestCase, pushLuaExpr)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assert, assertBool, assertEqual, testCase)

import qualified Data.ByteString.Char8 as B
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

-- | Specifications for Attributes parsing functions.
tests :: TestTree
tests = testGroup "lua integration tests"
  [ testCase "print version" .
    runLua $ do
      openlibs
      getglobal "assert"
      push ("Hello from " :: ByteString)
      getglobal "_VERSION"
      concat 2
      call 1 0

  , testCase "functions stored in / retrieved from registry" .
    runLua $ do
      pushLuaExpr "function() return 2 end, function() return 1 end"
      idx1 <- ref registryindex
      idx2 <- ref registryindex
      -- functions are removed from stack
      liftIO . assert =<< fmap (TFUNCTION /=) (ltype (-1))

      -- get functions from registry
      rawgeti registryindex idx1
      call 0 1
      r1 <- peek (-1) :: Lua LuaInteger
      liftIO (assert (r1 == 1))

      rawgeti registryindex idx2
      call 0 1
      r2 <- peek (-1) :: Lua LuaInteger
      liftIO (assert (r2 == 2))

      -- delete references
      unref registryindex idx1
      unref registryindex idx2

  , luaTestCase "getting a nested global works" $ do
      pushLuaExpr "{greeting = 'Moin'}"
      setglobal "hamburg"

      getglobal' "hamburg.greeting"
      pushLuaExpr "'Moin'"
      equal (-1) (-2)

  , testCase "table reading" .
    runLua $ do
      openbase
      let tableStr = "{firstname = 'Jane', surname = 'Doe'}"
      pushLuaExpr $ "setmetatable(" <> tableStr <> ", {'yup'})"
      getfield (-1) "firstname"
      firstname <- peek (-1) <* pop 1 :: Lua ByteString
      liftIO (assert (firstname == "Jane"))

      push ("surname" :: ByteString)
      rawget (-2)
      surname <- peek (-1) <* pop 1 :: Lua ByteString
      liftIO (assert (surname == "Doe"))

      hasMetaTable <- getmetatable (-1)
      liftIO (assert hasMetaTable)
      rawgeti (-1) 1
      mt1 <- peek (-1) <* pop 1 :: Lua ByteString
      liftIO (assert (mt1 == "yup"))

  , testGroup "stack values"
    [ testCase "unicode ByteString" $ do
        let val = T.pack "öçşiğüİĞı"
        val' <- runLua $ do
          pushstring (T.encodeUtf8 val)
          T.decodeUtf8 `fmap` tostring 1
        assertEqual "Popped a different value or pop failed" val val'

    , testCase "ByteString should survive after GC/Lua destroyed" $ do
        (val, val') <- runLua $ do
          let v = B.pack "ByteString should survive"
          pushstring v
          v' <- tostring 1
          pop 1
          return (v, v')
        performMajorGC
        assertEqual "Popped a different value or pop failed" val val'
    , testCase "String with NUL byte should be pushed/popped correctly" $ do
        let str = "A\NULB"
        str' <- runLua $ pushstring (B.pack str) *> tostring 1
        assertEqual "Popped string is different than what's pushed"
          str (B.unpack str')
    ]

  , testGroup "luaopen_* functions" $ map (uncurry testOpen)
    [ ("debug", opendebug)
    , ("io", openio)
    , ("math", openmath)
    , ("os", openos)
    , ("package", openpackage)
    , ("string", openstring)
    , ("table", opentable)
    ]
  , testGroup "luaopen_base returns the right number of tables" testOpenBase
  ]

--------------------------------------------------------------------------------
-- luaopen_* functions

testOpen :: String -> Lua () -> TestTree
testOpen lib openfn = testCase ("open" ++ lib) $
  assertBool "opening the library failed" =<<
  runLua (openfn *> istable (-1))

testOpenBase :: [TestTree]
testOpenBase = (:[]) .
  testCase "openbase" $
  assertBool "loading base didn't push the expected number of tables" =<<
  (runLua $ do
    -- openbase returns one table in lua 5.2 and later, but two in 5.1
    openbase
    getglobal "_VERSION"
    version <- peek (-1) <* pop 1
    if version == ("Lua 5.1" :: ByteString)
      then (&&) <$> istable (-1) <*> istable (-2)
      else istable (-1))
