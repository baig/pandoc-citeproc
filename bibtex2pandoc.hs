-- Experimental:
-- goes from bibtex to yaml directly, without bibutils
-- properly parses LaTeX bibtex fields, including math
-- does not yet support biblatex fields
-- probably does not support bibtex accurately
module Main where
import Text.BibTeX.Entry
import Text.BibTeX.Parse hiding (identifier, entry)
import Text.Parsec.String
import Text.Parsec hiding (optional, (<|>))
import Control.Applicative
import Text.Pandoc
import qualified Data.Map as M
import Data.List.Split (splitOn, splitWhen)
import Data.List (intersperse)
import Data.Maybe
import Data.Char (toLower, isUpper)
import System.Console.GetOpt
import System.Environment
import System.Exit
import System.IO (stderr, hPutStrLn)
import Control.Monad
import Control.Monad.RWS.Strict
import System.Environment (getEnvironment)
import qualified Data.Text as T

main :: IO ()
main = do
  argv <- getArgs
  let (flags, args, errs) = getOpt Permute options argv
  let header = "Usage: bibtex2pandoc [OPTION..] [FILE]"
  unless (null errs && length args < 2) $ do
    hPutStrLn stderr $ usageInfo (unlines $ errs ++ [header]) options
    exitWith $ ExitFailure 1
  when (Version `elem` flags) $ do
    putStrLn $ "bibtex2pandoc " ++ "0.0" -- TODO: showVersion version
    exitWith ExitSuccess
  when (Help `elem` flags) $ do
    putStrLn $ usageInfo header options
    exitWith ExitSuccess
  let isBibtex = Bibtex `elem` flags
  env <- getEnvironment
  let lang = case lookup "LANG" env of
                  Just x  -> case splitWhen (\c -> c == '.' || c == '_') x of
                                   (w:z:_) -> Lang w z
                                   [w]     -> Lang w ""
                                   _       -> Lang "en" "US"
                  Nothing -> Lang "en" "US"
  bibstring <- case args of
                    (x:_) -> readFile x
                    []    -> getContents
  let items = case parse (skippingLeadingSpace file) "stdin" bibstring of
                   Left err -> error (show err)
                   Right xs -> resolveCrossRefs isBibtex
                                  $ map lowercaseFieldNames xs
  putStrLn
    $ writeMarkdown def{ writerTemplate = "$titleblock$"
                       , writerStandalone = True }
    $ Pandoc (Meta $ M.fromList [
                     ("references" , MetaList
                                    $ map (itemToMetaValue lang isBibtex) items)
                     ]
             ) []

data Option =
    Help | Version | Bibtex
  deriving (Ord, Eq, Show)

options :: [OptDescr Option]
options =
  [ Option ['b'] ["bibtex"] (NoArg Bibtex) "parse as BibTeX, not BibLaTeX"
  , Option ['h'] ["help"] (NoArg Help) "show usage information"
  , Option ['V'] ["version"] (NoArg Version) "show program version"
  ]

lowercaseFieldNames :: T -> T
lowercaseFieldNames e = e{ fields = [(map toLower f, v) | (f,v) <- fields e] }

resolveCrossRefs :: Bool -> [T] -> [T]
resolveCrossRefs isBibtex entries =
  map (resolveCrossRef isBibtex entries) entries

resolveCrossRef :: Bool -> [T] -> T -> T
resolveCrossRef isBibtex entries entry =
  case lookup "crossref" (fields entry) of
       Just xref -> case [e | e <- entries, identifier e == xref] of
                         []     -> entry
                         (e':_)
                          | isBibtex -> entry{ fields = fields entry ++
                                           [(k,v) | (k,v) <- fields e',
                                            isNothing (lookup k $ fields entry)]
                                        }
                          | otherwise -> entry{ fields = fields entry ++
                                          [(k',v) | (k,v) <- fields e',
                                            k' <- transformKey (entryType e')
                                                   (entryType entry) k,
                                           isNothing (lookup k' (fields entry))]
                                              }
       Nothing   -> entry

-- transformKey source target key
-- derived from Appendix C of bibtex manual
transformKey :: String -> String -> String -> [String]
transformKey _ _ "crossref"       = []
transformKey _ _ "xref"           = []
transformKey _ _ "entryset"       = []
transformKey _ _ "entrysubtype"   = []
transformKey _ _ "execute"        = []
transformKey _ _ "label"          = []
transformKey _ _ "options"        = []
transformKey _ _ "presort"        = []
transformKey _ _ "related"        = []
transformKey _ _ "relatedstring"  = []
transformKey _ _ "relatedtype"    = []
transformKey _ _ "shorthand"      = []
transformKey _ _ "shorthandintro" = []
transformKey _ _ "sortkey"        = []
transformKey x y "author"
  | x `elem` ["mvbook", "book"] &&
    y `elem` ["inbook", "bookinbook", "suppbook"] = ["bookauthor"]
transformKey "mvbook" y z
  | y `elem` ["book", "inbook", "bookinbook", "suppbook"] = standardTrans z
transformKey x y z
  | x `elem` ["mvcollection", "mvreference"] &&
    y `elem` ["collection", "reference", "incollection", "suppbook"] =
    standardTrans z
transformKey "mvproceedings" y z
  | y `elem` ["proceedings", "inproceedings"] = standardTrans z
transformKey "book" y z
  | y `elem` ["inbook", "bookinbook", "suppbook"] = standardTrans z
transformKey x y z
  | x `elem` ["collection", "reference"] &&
    y `elem` ["incollection", "inreference", "suppcollection"] = standardTrans z
transformKey "proceedings" "inproceedings" z = standardTrans z
transformKey "periodical" y z
  | y `elem` ["article", "suppperiodical"] =
  case z of
       "title"          -> ["journaltitle"]
       "subtitle"       -> ["journalsubtitle"]
       "shorttitle"     -> []
       "sorttitle"      -> []
       "indextitle"     -> []
       "indexsorttitle" -> []
transformKey _ _ x                = [x]

standardTrans :: String -> [String]
standardTrans z =
  case z of
       "title"          -> ["maintitle"]
       "subtitle"       -> ["mainsubtitle"]
       "titleaddon"     -> ["maintitleaddon"]
       "shorttitle"     -> []
       "sorttitle"      -> []
       "indextitle"     -> []
       "indexsorttitle" -> []
       _                -> [z]

type BibM = RWST T () (M.Map String MetaValue) Maybe

opt :: BibM () -> BibM ()
opt m = m `mplus` return ()

getField :: String -> BibM MetaValue
getField f = do
  fs <- asks fields
  case lookup f fs of
       Just x  -> return $ latex x
       Nothing -> fail "not found"

setField :: String -> MetaValue -> BibM ()
setField f x = modify $ M.insert f x

appendField :: String -> ([Inline] -> [Inline]) -> MetaValue -> BibM ()
appendField f fn x = modify $ M.insertWith combine f x
  where combine new old = MetaInlines $ toInlines old ++ fn (toInlines new)
        toInlines (MetaInlines ils) = ils
        toInlines (MetaBlocks [Para ils]) = ils
        toInlines (MetaBlocks [Plain ils]) = ils
        toInlines _ = []

notFound :: String -> BibM a
notFound f = fail $ f ++ " not found"

getId :: BibM String
getId = asks identifier

getRawField :: String -> BibM String
getRawField f = do
  fs <- asks fields
  case lookup f fs of
       Just x  -> return x
       Nothing -> notFound f

setRawField :: String -> String -> BibM ()
setRawField f x = modify $ M.insert f (MetaString x)

getAuthorList :: String -> BibM [MetaValue]
getAuthorList f = do
  fs <- asks fields
  case lookup f fs of
       Just x  -> return $ toAuthorList $ latex x
       Nothing -> notFound f

getLiteralList :: String -> BibM [MetaValue]
getLiteralList f = do
  fs <- asks fields
  case lookup f fs of
       Just x  -> return $ toLiteralList $ latex x
       Nothing -> notFound f

setList :: String -> [MetaValue] -> BibM ()
setList f xs = modify $ M.insert f $ MetaList xs

setSubField :: String -> String -> MetaValue -> BibM ()
setSubField f k v = do
  fs <- get
  case M.lookup f fs of
       Just (MetaMap m) -> modify $ M.insert f (MetaMap $ M.insert k v m)
       _ -> modify $ M.insert f (MetaMap $ M.singleton k v)

bibItem :: BibM a -> T -> MetaValue
bibItem m entry = MetaMap $ maybe M.empty fst $ execRWST m entry M.empty

getEntryType :: BibM String
getEntryType = asks entryType

isPresent :: String -> BibM Bool
isPresent f = do
  fs <- asks fields
  case lookup f fs of
       Just _   -> return True
       Nothing  -> return False

unTitlecase :: MetaValue -> MetaValue
unTitlecase (MetaInlines ils) = MetaInlines $ untc ils
unTitlecase (MetaBlocks [Para ils]) = MetaBlocks [Para $ untc ils]
unTitlecase (MetaBlocks [Plain ils]) = MetaBlocks [Para $ untc ils]

untc :: [Inline] -> [Inline]
untc [] = []
untc (x:xs) = x : map go xs
  where go (Str ys)     = Str $ map toLower ys
        go z            = z

toLocale :: String -> String
toLocale "english"    = "en-US" -- "en-EN" unavailable in CSL
toLocale "USenglish"  = "en-US"
toLocale "american"   = "en-US"
toLocale "british"    = "en-GB"
toLocale "UKenglish"  = "en-GB"
toLocale "canadian"   = "en-US" -- "en-CA" unavailable in CSL
toLocale "australian" = "en-GB" -- "en-AU" unavailable in CSL
toLocale "newzealand" = "en-GB" -- "en-NZ" unavailable in CSL
toLocale "afrikaans"  = "af-ZA"
toLocale "arabic"     = "ar"
toLocale "basque"     = "eu"
toLocale "bulgarian"  = "bg-BG"
toLocale "catalan"    = "ca-AD"
toLocale "croatian"   = "hr-HR"
toLocale "czech"      = "cs-CZ"
toLocale "danish"     = "da-DK"
toLocale "dutch"      = "nl-NL"
toLocale "estonian"   = "et-EE"
toLocale "finnish"    = "fi-FI"
toLocale "canadien"   = "fr-CA"
toLocale "acadian"    = "fr-CA"
toLocale "french"     = "fr-FR"
toLocale "francais"   = "fr-FR"
toLocale "austrian"   = "de-AT"
toLocale "naustrian"  = "de-AT"
toLocale "german"     = "de-DE"
toLocale "germanb"    = "de-DE"
toLocale "ngerman"    = "de-DE"
toLocale "greek"      = "el-GR"
toLocale "polutonikogreek" = "el-GR"
toLocale "hebrew"     = "he-IL"
toLocale "hungarian"  = "hu-HU"
toLocale "icelandic"  = "is-IS"
toLocale "italian"    = "it-IT"
toLocale "japanese"   = "ja-JP"
toLocale "latvian"    = "lv-LV"
toLocale "lithuanian" = "lt-LT"
toLocale "magyar"     = "hu-HU"
toLocale "mongolian"  = "mn-MN"
toLocale "norsk"      = "nb-NO"
toLocale "nynorsk"    = "nn-NO"
toLocale "farsi"      = "fa-IR"
toLocale "polish"     = "pl-PL"
toLocale "brazil"     = "pt-BR"
toLocale "brazilian"  = "pt-BR"
toLocale "portugues"  = "pt-PT"
toLocale "portuguese" = "pt-PT"
toLocale "romanian"   = "ro-RO"
toLocale "russian"    = "ru-RU"
toLocale "serbian"    = "sr-RS"
toLocale "serbianc"   = "sr-RS"
toLocale "slovak"     = "sk-SK"
toLocale "slovene"    = "sl-SL"
toLocale "spanish"    = "es-ES"
toLocale "swedish"    = "sv-SE"
toLocale "thai"       = "th-TH"
toLocale "turkish"    = "tr-TR"
toLocale "ukrainian"  = "uk-UA"
toLocale "vietnamese" = "vi-VN"
toLocale _            = ""

itemToMetaValue :: Lang -> Bool -> T -> MetaValue
itemToMetaValue lang bibtex = bibItem $ do
  getId >>= setRawField "id"
  et <- map toLower `fmap` getEntryType
  let setType = setRawField "type"
  let lang = Lang "en" "US" -- for now, later might get as parameter
  case et of
       "article"         -> setType "article-journal"
       "book"            -> setType "book"
       "booklet"         -> setType "pamphlet"
       "bookinbook"      -> setType "book"
       "collection"      -> setType "book"
       "electronic"      -> setType "webpage"
       "inbook"          -> setType "chapter"
       "incollection"    -> setType "chapter"
       "inreference "    -> setType "chapter"
       "inproceedings"   -> setType "paper-conference"
       "manual"          -> setType "book"
       "mastersthesis"   -> setType "thesis" >>
                             setRawField "genre" "Master’s thesis"
       "misc"            -> setType "no-type"
       "mvbook"          -> setType "book"
       "mvcollection"    -> setType "book"
       "mvproceedings"   -> setType "book"
       "mvreference"     -> setType "book"
       "online"          -> setType "webpage"
       "patent"          -> setType "patent"
       "periodical"      -> setType "article-journal"
       "phdthesis"       -> setType "thesis" >>
                             setRawField "genre" "Ph.D. thesis"
       "proceedings"     -> setType "book"
       "reference"       -> setType "book"
       "report"          -> setType "report"
       "suppbook"        -> setType "chapter"
       "suppcollection"  -> setType "chapter"
       "suppperiodical"  -> setType "article-journal"
       "techreport"      -> setType "report"
       "thesis"          -> setType "thesis"
       "unpublished"     -> setType "manuscript"
       "www"             -> setType "webpage"
       -- biblatex, "unsupported"
       "artwork"         -> setType "graphic"
       "audio"           -> setType "song"              -- for audio *recordings*
       "commentary"      -> setType "book"
       "image"           -> setType "graphic"           -- or "figure" ?
       "jurisdiction"    -> setType "legal_case"
       "legislation"     -> setType "legislation"       -- or "bill" ?
       "legal"           -> setType "treaty"
       "letter"          -> setType "personal_communication"
       "movie"           -> setType "motion_picture"
       "music"           -> setType "song"              -- for musical *recordings*
       "performance"     -> setType "speech"
       "review"          -> setType "review"            -- or "review-book" ?
       "software"        -> setType "book"              -- for lack of any better match
       "standard"        -> setType "legislation"
       "video"           -> setType "motion_picture"
       -- biblatex-apa:
       "data"            -> setType "dataset"
       "letters"         -> setType "personal_communication"
       "newsarticle"     -> setType "article-newspaper"
       _                 -> setType "no-type"

-- Use entrysubtype to tweak CSL type:
  opt $ do
    val <- getRawField "entrysubtype"
--    if  (et == "article" || et == "periodical" || et == "suppperiodical") && val == "magazine"
    if  (et `elem` ["article","periodical","suppperiodical"]) && val == "magazine"
    then setType "article-magazine"
    else return ()
-- hyphenation:
  hyphenation <- getRawField "hyphenation" <|> return "english"
  let processTitle = if (map toLower hyphenation) `elem`
                        ["american","british","canadian","english",
                         "australian","newzealand","usenglish","ukenglish"]
                     then unTitlecase
                     else id
  opt $ getRawField "hyphenation" >>= setRawField "language" . toLocale
-- author, editor:
  opt $ getAuthorList "author" >>= setList "author"
  opt $ getAuthorList "bookauthor" >>= setList "container-author"
  opt $ getAuthorList "translator" >>= setList "translator"
  hasEditortype <- isPresent "editortype"
  opt $ if hasEditortype then
    do
      val <- getRawField "editortype"
      getAuthorList "editor" >>=  setList (
        case val of
        "editor"       -> "editor"             -- from here on biblatex & CSL
        "compiler"     -> "editor"             -- from here on biblatex only;
        "founder"      -> "editor"             --   not optimal, but all can
        "continuator"  -> "editor"             --   somehow be subsumed under
        "redactor"     -> "editor"             --   "editor"
        "reviser"      -> "editor"
        "collaborator" -> "editor"
        "director"     -> "director"           -- from here on biblatex-chicago & CSL
  --    "conductor"    -> ""                   -- from here on biblatex-chicago only
  --    "producer"     -> ""
  --    "none"         -> ""                   -- meant for performer(s)
  --    ""             -> "editorial-director" -- from here on CSL only
  --    ""             -> "composer"
  --    ""             -> "illustrator"
  --    ""             -> "interviewer"
  --    ""             -> "collection-editor"
        _              -> "editor")
    else opt $ getAuthorList "editor" >>= setList "editor"

-- FIXME: add same for editora, editorb, editorc

  opt $ getAuthorList "director" >>= setList "director"
  -- director from biblatex-apa, which has also producer, writer, execproducer (FIXME?)
-- dates:
  opt $ getField "year" >>= setSubField "issued" "year"
  opt $ getField "month" >>= setSubField "issued" "month"
--  opt $ getField "date" >>= setField "issued" -- FIXME
  opt $ do
    dateraw <- getRawField "date"
    let datelist = T.splitOn (T.pack "-") (T.pack dateraw)
    let year = T.unpack (datelist !! 0)
    if length (datelist) > 1
    then do
      let month = T.unpack (datelist !! 1)
      setSubField "issued" "month" (MetaString month)
      if length (datelist) > 2
      then do
        let day = T.unpack (datelist !! 2)
        setSubField "issued" "day" (MetaString day)
      else return ()
    else return ()
    setSubField "issued" "year" (MetaString year)
--  opt $ getField "urldate" >>= setField "accessed" -- FIXME
  opt $ do
    dateraw <- getRawField "urldate"
    let datelist = T.splitOn (T.pack "-") (T.pack dateraw)
    let year = T.unpack (datelist !! 0)
    if length (datelist) > 1
    then do
      let month = T.unpack (datelist !! 1)
      setSubField "accessed" "month" (MetaString month)
      if length (datelist) > 2
      then do
        let day = T.unpack (datelist !! 2)
        setSubField "accessed" "day" (MetaString day)
      else return ()
    else return ()
    setSubField "accessed" "year" (MetaString year)
  opt $ getField "eventdate" >>= setField "event-date"   -- FIXME
  opt $ getField "origdate" >>= setField "original-date" -- FIXME
-- titles:
  opt $ getField "title" >>= setField "title" . processTitle
  opt $ getField "subtitle" >>= appendField "title" addColon . processTitle
  opt $ getField "titleaddon" >>= appendField "title" addPeriod . processTitle
  opt $ getField "maintitle" >>= setField "container-title" . processTitle
  opt $ getField "mainsubtitle" >>=
        appendField "container-title" addColon . processTitle
  opt $ getField "maintitleaddon" >>=
             appendField "container-title" addPeriod . processTitle
  hasMaintitle <- isPresent "maintitle"
  opt $ getField "booktitle" >>=
             setField (if hasMaintitle &&
                          et `elem` ["inbook","incollection","inproceedings","bookinbook"]
                       then "volume-title"
                       else "container-title") . processTitle
  opt $ getField "booksubtitle" >>=
             appendField (if hasMaintitle &&
                             et `elem` ["inbook","incollection","inproceedings","bookinbook"]
                          then "volume-title"
                          else "container-title") addColon . processTitle
  opt $ getField "booktitleaddon" >>=
             appendField (if hasMaintitle &&
                             et `elem` ["inbook","incollection","inproceedings","bookinbook"]
                          then "volume-title"
                          else "container-title") addPeriod . processTitle
  opt $ getField "shorttitle" >>= setField "title-short" . processTitle
  -- handling of "periodical" to be revised as soon as new "issue-title" variable
  --   is included into CSL specs
  -- A biblatex "note" field in @periodical usually contains sth. like "Special issue"
  -- At least for CMoS, APA, borrowing "genre" for this works reasonably well.
  opt $ do
    if  et == "periodical" then do
      opt $ getField "title" >>= setField "container-title"
      opt $ getField "issuetitle" >>= setField "title" . processTitle
      opt $ getField "issuesubtitle" >>= appendField "title" addColon . processTitle
      opt $ getField "note" >>= appendField "genre" addPeriod . processTitle
    else return ()
  opt $ getField "journal" >>= setField "container-title"
  opt $ getField "journaltitle" >>= setField "container-title"
  opt $ getField "journalsubtitle" >>= appendField "container-title" addColon
  opt $ getField "shortjournal" >>= setField "container-title-short"
  opt $ getField "series" >>= appendField (if et `elem` ["article","periodical","suppperiodical"]
                                        then "container-title"
                                        else "collection-title") addComma
  opt $ getField "eventtitle" >>= setField "event"
  opt $ getField "origtitle" >>= setField "original-title"
-- publisher, location:
--   opt $ getField "school" >>= setField "publisher"
--   opt $ getField "institution" >>= setField "publisher"
--   opt $ getField "organization" >>= setField "publisher"
--   opt $ getField "howpublished" >>= setField "publisher"
--   opt $ getField "publisher" >>= setField "publisher"

  opt $ getField "school" >>= appendField "publisher" addComma
  opt $ getField "institution" >>= appendField "publisher" addComma
  opt $ getField "organization" >>= appendField "publisher" addComma
  opt $ getField "howpublished" >>= appendField "publisher" addComma
  opt $ getField "publisher" >>= appendField "publisher" addComma

  opt $ getField "address" >>= setField "publisher-place"
  unless bibtex $ do
    opt $ getField "location" >>= setField "publisher-place"
  opt $ getLiteralList "venue" >>= setList "event-place"
  opt $ getLiteralList "origlocation" >>=
             setList "original-publisher-place"
  opt $ getLiteralList "origpublisher" >>= setList "original-publisher"
-- numbers, locators etc.:
  opt $ getField "pages" >>= setField "page"
  opt $ getField "volume" >>= setField "volume"
  opt $ getField "number" >>=
             setField (if et `elem` ["article","periodical","suppperiodical"]
                       then "issue"
                       else if et `elem` ["book","collection","proceedings","reference",
                       "mvbook","mvcollection","mvproceedings","mvreference",
                       "bookinbook","inbook","incollection","inproceedings","inreference",
                       "suppbook","suppcollection"]
                       then "collection-number"
                       else "number")                     -- "report", "patent", etc.
  opt $ getField "issue" >>= appendField "issue" addComma
  opt $ getField "chapter" >>= setField "chapter-number"
  opt $ getField "edition" >>= setField "edition"
  opt $ getField "pagetotal" >>= setField "number-of-pages"
  opt $ getField "volumes" >>= setField "number-of-volumes"
  opt $ getField "version" >>= setField "version"
  opt $ getRawField "type" >>= setRawField "genre" . resolveKey lang
  opt $ getRawField "pubstate" >>= setRawField "status" . resolveKey lang
-- url, doi, isbn, etc.:
  opt $ getRawField "url" >>= setRawField "url"
  opt $ getRawField "doi" >>= setRawField "doi"
  opt $ getRawField "isbn" >>= setRawField "isbn"
  opt $ getRawField "issn" >>= setRawField "issn"
-- note etc.
  unless (et == "periodical") $ do
    opt $ getField "note" >>= setField "note"
  unless bibtex $ do
    opt $ getField "addendum" >>= appendField "note" (Space:)
  opt $ getField "annotation" >>= setField "annote"
  opt $ getField "annote" >>= setField "annote"
  opt $ getField "abstract" >>= setField "abstract"
  opt $ getField "keywords" >>= setField "keyword"

addColon :: [Inline] -> [Inline]
addColon xs = [Str ":",Space] ++ xs

addComma :: [Inline] -> [Inline]
addComma xs = [Str ",",Space] ++ xs

addPeriod :: [Inline] -> [Inline]
addPeriod xs = [Str ".",Space] ++ xs

inParens :: [Inline] -> [Inline]
inParens xs = [Space, Str "("] ++ xs ++ [Str ")"]

splitByAnd :: [Inline] -> [[Inline]]
splitByAnd = splitOn [Space, Str "and", Space]

toLiteralList :: MetaValue -> [MetaValue]
toLiteralList (MetaBlocks [Para xs]) =
  map MetaInlines $ splitByAnd xs
toLiteralList (MetaBlocks []) = []
toLiteralList x = error $ "toLiteralList: " ++ show x

toAuthorList :: MetaValue -> [MetaValue]
toAuthorList (MetaBlocks [Para xs]) =
  map toAuthor $ splitByAnd xs
toAuthorList (MetaBlocks []) = []
toAuthorList x = error $ "toAuthorList: " ++ show x

toAuthor :: [Inline] -> MetaValue
toAuthor [Span ("",[],[]) ils] = -- corporate author
  MetaMap $ M.singleton "literal" $ MetaInlines ils
toAuthor ils = MetaMap $ M.fromList $
  [ ("given", MetaList givens)
  , ("family", family)
  ] ++ case particle of
            MetaInlines [] -> []
            _              -> [("non-dropping-particle", particle)]
  where endsWithComma (Str zs) = not (null zs) && last zs == ','
        endsWithComma _ = False
        stripComma xs = case reverse xs of
                             (',':ys) -> reverse ys
                             _ -> xs
        (xs, ys) = break endsWithComma ils
        (family, givens, particle) =
           case splitOn [Space] ys of
              ((Str w:ws) : rest) ->
                  ( MetaInlines [Str (stripComma w)]
                  , map MetaInlines $ if null ws then rest else (ws : rest)
                  , MetaInlines xs
                  )
              _ -> case reverse xs of
                        []     -> (MetaInlines [], [], MetaInlines [])
                        (z:zs) -> let (us,vs) = break startsWithCapital zs
                                  in  ( MetaInlines [z]
                                      , map MetaInlines $ splitOn [Space] $ reverse vs
                                      , MetaInlines $ dropWhile (==Space) $ reverse us
                                      )

startsWithCapital :: Inline -> Bool
startsWithCapital (Str (x:_)) = isUpper x
startsWithCapital _           = False

latex :: String -> MetaValue
latex s = MetaBlocks bs
  where Pandoc _ bs = readLaTeX def s

trim :: String -> String
trim = unwords . words

data Lang = Lang String String  -- e.g. "en" "US"

resolveKey :: Lang -> String -> String
resolveKey (Lang "en" "US") k =
  case k of
       "inpreparation" -> "in preparation"
       "submitted"     -> "submitted"
       "forthcoming"   -> "forthcoming"
       "inpress"       -> "in press"
       "prepublished"  -> "pre-published"
       "mathesis"      -> "Master’s thesis"
       "phdthesis"     -> "PhD thesis"
       "candthesis"    -> "Candidate thesis"
       "techreport"    -> "technical report"
       "resreport"     -> "research report"
       "software"      -> "computer software"
       "datacd"        -> "data CD"
       "audiocd"       -> "audio CD"
       _               -> k
resolveKey _ k = resolveKey (Lang "en" "US") k
