{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           Common
import           Data.Char
import           Data.List
import           Data.List.Split
import           Data.String.Utils
import qualified Data.Text         as T
import           Network.Curl
import           Post
import           System.Process
import           Text.HTML.Scalpel

url :: URL
url = "https://semanticsarchive.net/cgi-bin/browse.pl"

main = do
  -- move things into place
  callCommand $ "touch idents.txt; mv idents.txt idents_old.txt"
  -- scrape the semarch for all the <a href=...> attributes
  scraped <- scrapeURL url (attrs "href" "a")
  -- peel off the Maybe
  links <- maybe (return "error!") (return . concat) scraped
  -- load the old identifiers
  oldLinks <- readFile "idents_old.txt"
  -- parse out the scraped identifiers
  let processed = off links
  -- find the new identifiers among the scraped
  let newLinks = filter (not . (`elem` lines oldLinks)) (lines processed)
  -- save the scraped identifiers
  writeFile "idents.txt" processed
  -- compose twetes for new identifiers
  twetes <- mapM composeTwete newLinks
  mapM_ post $ reverse (map T.pack twetes)

off, on :: String -> String -- extract the semarch identifiers w/ a
                            -- couple mutually recursive functions
off "error!"                             = "error!"
off []                                   = []
off ('A':'r':'c':'h':'i':'v':'e':'/':xs) = on xs
off (x:xs)                               = off xs
--
on [] = []
on xs = if all isAlphaNum ident then ident ++ '\n' : off go else off go
  where ident = take 8 xs
        go    = drop 8 xs

composeTwete :: String -> IO String
composeTwete ident = do
  (_, info) <- curlGetString ("https://semanticsarchive.net/Archive/"++
                              ident ++"/info.txt") []
  return (process ident $ replace "And " "& " (replace "and " "& " info))

process :: String -> String -> String
process ident info = let authorTitle = unwords . words $ -- rmv double-spaces
                                       getAuthors info ++
                                       ": "++ getTitle info in
                     let link = " https://semanticsarchive.net/Archive/"++ ident in
                     let keywords = getKeywords info in
                     mini authorTitle link keywords

mini authorTitle link [] = authorTitle ++ link
mini authorTitle link xs = if shortEnough authorTitle link xs
                           then authorTitle ++ link ++" " ++ unwords xs
                           else mini authorTitle link (reverse (drop 1 (reverse xs)))
                             where shortEnough authorTitle link xs =
                                     length (authorTitle ++ unwords xs) < 116

getAuthors, getTitle :: String -> String
getAuthors xs =
  let gotIt = drop 11 (head (filter (isPrefixOf "Author(s): ") (lines xs))) in
  let auths = filter (not . isControl) gotIt in
  if mults auths then etAl auths else takeWhile (/= ',') auths
    where mults auths = length (splitOn "&" auths) > 1 ||
                        length (splitOn "," auths) > 2
          etAl auths = if length (findIndices (== '&') auths) > 1 ||
                          length (findIndices (== ',') auths) > 3 ||
                          length (findIndices (\x -> x == '&' || x == ',') auths) > 3
                       then takeWhile (/= ',') auths ++" et al"
                       else twoAuths auths
          twoAuths auths = takeWhile (/= ',') auths ++" & "++
                           lastAuth (drop 2 (dropWhile (\x -> x /= ',' && x /= '&')
                                                       (tail $ dropWhile (/= ',') auths)))
          lastAuth str = if any (== ',') str
                         then init (head (words str))
                         else unwords (filter (isLower . head) (words str)) ++" "++ last (words str)
--
getTitle = filter (not . isControl) . takeWhile (\x -> x /= ':') . drop 7 .
           head . filter (isPrefixOf "Title: ") . lines

getKeywords :: String -> [String]
getKeywords input = if length (test input) > 0 then map (filter (\x -> x /= ' ' && x /= '-')) . map ("#"++) . map (filter (not . isControl)) . take 3 . splitOn ", " . drop 10 . head $ test input else [[]]
  where test input = filter (isPrefixOf "Keywords: ") (lines input)
