import Foundation

// Generated from:
// - https://www.unicode.org/Public/17.0.0/ucd/StandardizedVariants.txt
// - https://www.unicode.org/Public/17.0.0/ucd/emoji/emoji-variation-sequences.txt
// - https://github.com/unicode-org/cldr/tree/release-48/common/validity
// Source data is provided under the Unicode License v3.
enum UnicodeSequenceData {
    static func isRegisteredVariationSequence(base: Unicode.Scalar, selector: Unicode.Scalar) -> Bool {
        guard (0xFE00...0xFE0F).contains(selector.value) else { return false }
        let key = (base.value << 4) | (selector.value - 0xFE00)
        var lowerBound = registeredVariationSequenceKeys.startIndex
        var upperBound = registeredVariationSequenceKeys.endIndex
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            let candidate = registeredVariationSequenceKeys[middle]
            if candidate == key { return true }
            if candidate < key { lowerBound = middle + 1 } else { upperBound = middle }
        }
        return false
    }

    static func isValidSubdivisionIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty, identifier.utf8.allSatisfy({
            (0x30...0x39).contains($0) || (0x61...0x7A).contains($0)
        }) else { return false }
        if identifier.count == 3, identifier.allSatisfy(\.isNumber) {
            return contains(identifier, in: validNumericRegionTokens)
        }
        return contains(identifier, in: validSubdivisionTokens)
    }

    private static func contains(_ identifier: String, in tokens: [Substring]) -> Bool {
        for token in tokens {
            guard let separator = token.firstIndex(of: "~") else {
                if identifier == token { return true }
                continue
            }
            let start = token[..<separator]
            let suffix = token[token.index(after: separator)...]
            guard suffix.count <= start.count else { continue }
            let end = start.dropLast(suffix.count) + suffix
            if identifier.count == start.count, identifier >= start, identifier <= end {
                return true
            }
        }
        return false
    }

    private static let validSubdivisionTokens = subdivisionTokenData.split(whereSeparator: \.isWhitespace)
    private static let validNumericRegionTokens = numericRegionTokenData.split(whereSeparator: \.isWhitespace)

    private static let subdivisionTokenData = """
        ad02~8 aeaj aeaz aedu aefu aerk aesh aeuq afbal~m afbdg afbds afbgl
        afday affra affyb afgha afgho afhel afher afjow afkab afkan afkap afkdz
        afkho afknr aflag aflog afnan afnim afnur afpan afpar afpia afpka afsam
        afsar aftak afuru afwar afzab ag03~8 ag10~1 al01~9 al10~2 amag amar amav
        amer amgr amkt amlo amsh amsu amtv amvd aobgo aobgu aobie aocab
        aoccu aocnn~o aocus aohua aohui aolno aolsu aolua aomal aomox aonam aouig
        aozai ara~h arj~n arp~z at1~9 auact aunsw aunt auqld ausa autas auvic
        auwa azabs azaga azagc azagm azags azagu azast azba azbab azbal azbar
        azbey azbil azcab azcal azcul azdas azfuz azga azgad azgor azgoy azgyg
        azhac azimi azism azkal azkan azkur azla azlac azlan azler azmas azmi
        azna aznef aznv aznx azogu azord azqab azqax azqaz azqba azqbi azqob
        azqus azsa azsab azsad azsah azsak~l azsar azsat azsbn azsiy azskr azsm
        azsmi azsmx azsr azsus aztar aztov azuca azxa azxac azxci azxiz azxvd
        azyar azye azyev azzan azzaq~r babih babrc basrp bb01~9 bb10~1 bd01~9 bd10~9
        bd20~9 bd30~9 bd40~9 bd50~9 bd60~4 bda~h bebru bevan bevbr bevlg bevli bevov
        bevwv bewal bewbr bewht bewlg bewlx bewna bf01~9 bf10~3 bfbal~n bfbaz bfbgr
        bfblg bfblk bfcom bfgan bfgna bfgou bfhou bfiob bfkad bfken bfkmd bfkmp
        bfkop bfkos~t bfkow bfler bflor bfmou bfnam bfnao bfnay bfnou bfoub bfoud
        bfpas bfpon bfsen bfsis bfsmt bfsng bfsom bfsor bftap bftui bfyag bfyat
        bfzir bfzon bfzou bg01~9 bg10~9 bg20~8 bh13~5 bh17 bibb bibl~m bibr bica
        bici bigi biki bikr biky bima bimu bimw bimy bing birm birt
        biry bjak~l bjaq bjbo bjco bjdo bjko bjli bjmo bjou bjpl bjzo
        bnbe bnbm bnte bntu bob~c boh bol bon~p bos~t bqbo bqsa bqse
        brac bral~m brap brba brce brdf bres brgo brma brmg brms~t brpa~b
        brpe brpi brpr brrj brrn~o brrr~s brsc brse brsp brto bsak bsbi
        bsbp bsby bsce bsci bsck bsco bscs bseg bsex bsfp bsgc bshi
        bsht bsin bsli bsmc bsmg bsmi bsne bsno~p bsns bsrc bsri bssa
        bsse bsso bsss bssw bswg bt11~5 bt21~4 bt31~4 bt41~5 btga btty bwce
        bwch bwfr bwga bwgh bwjw bwkg bwkl bwkw bwlo bwne bwnw bwse
        bwso~p bwst bybr byhm byho byhr byma bymi byvi bzbz bzcy bzczl
        bzow bzsc bztol caab cabc camb canb canl cans~u caon cape caqc
        cask cayt cdbc cdbu cdeq cdhk~l cdhu cdit cdkc cdke cdkg cdkl
        cdkn cdks cdlo cdlu cdma cdmn~o cdnk cdnu cdsa cdsk cdsu cdta
        cdto cdtu cfac cfbb cfbgf cfbk cfhk cfhm cfhs cfkb cfkg cflb
        cfmb cfmp cfnm cfop cfse cfuk cfvk cg11~6 cg2 cg5 cg7~9 cgbzv
        chag chai char chbe chbl chbs chfr chge chgl chgr chju chlu
        chne chnw chow chsg~h chso chsz chtg chti chur chvd chvs chzg~h
        ciab cibs cicm cidn cigd cilc cilg cimg cism cisv civb ciwr
        ciym cizz clai clan clap clar clat clbi clco clli clll cllr
        clma clml clnb clrm clta clvs cmad cmce cmen cmes cmlt cmno
        cmnw cmou cmsu cmsw cnah cnbj cncq cnfj cngd cngs cngx cngz
        cnha~b cnhe cnhi cnhk~l cnhn cnjl cnjs cnjx cnln cnmo cnnm cnnx
        cnqh cnsc~d cnsh cnsn cnsx cntj cntw cnxj cnxz cnyn cnzj coama
        coant coara coatl cobol coboy cocal cocaq cocas cocau coces cocho cocor
        cocun codc cogua coguv cohui colag comag comet conar consa coput coqui
        coris cosan cosap cosuc cotol covac covau covid cra crc crg~h crl
        crp crsj cu01 cu03~9 cu10~6 cu99 cvb cvbr cvbv cvca cvcf cvcr
        cvma cvmo cvpa cvpn cvpr cvrb cvrg cvrs cvs cvsd cvsf cvsl~m
        cvso cvss cvsv cvta cvts cy01~6 cz10 cz20 cz201~9 cz20a~c cz31 cz311~7
        cz32 cz321~7 cz41 cz411~3 cz42 cz421~7 cz51 cz511~4 cz52 cz521~5 cz53 cz531~4
        cz63 cz631~5 cz64 cz641~7 cz71 cz711~5 cz72 cz721~4 cz80 cz801~6 debb debe
        debw deby dehb dehe dehh demv deni denw derp desh desl desn
        dest deth djar~s djdi~j djob djta dk81~5 dm02~9 dm10~1 do01~9 do10~9 do20~9
        do30~9 do40~2 dz01~9 dz10~9 dz20~9 dz30~9 dz40~9 dz50~8 eca~i ecl~p ecr~s ecsd~e
        ect~u ecw~z ee130 ee141~2 ee171 ee184 ee191 ee198 ee205 ee214 ee245 ee247
        ee251 ee255 ee272 ee283~4 ee291 ee293 ee296 ee303 ee305 ee317 ee321 ee338
        ee353 ee37 ee39 ee424 ee430~2 ee441~2 ee446 ee45 ee478 ee480 ee486 ee50
        ee503 ee511 ee514 ee52 ee528 ee557 ee56 ee567 ee586 ee60 ee615 ee618
        ee622 ee624 ee638 ee64 ee651 ee653 ee661 ee663 ee668 ee68 ee689 ee698
        ee708 ee71 ee712 ee714 ee719 ee726 ee732 ee735 ee74 ee784 ee79 ee792~3
        ee796 ee803 ee809 ee81 ee824 ee834 ee84 ee855 ee87 ee890 ee897 ee899
        ee901 ee903 ee907 ee917 ee919 ee928 egalx egasn egast egba egbh egbns
        egc egdk egdt egfym eggh eggz egis egjs egkb egkfs egkn eglx
        egmn egmnf egmt egpts egshg egshr egsin egsuz egwad eran erdk erdu
        ergb erma ersk esa esab esal esan esar~s esav esb esba esbi
        esbu esc esca~c esce escl~o escr~u esex esga esgc esgi esgr esgu
        esh eshu esib esj esl esle eslo eslu esm esma esmc~d esml
        esmu esna esnc eso esor esp espm espo espv esri ess essa
        esse essg esso esss est este~f esto esv esva esvc esvi esz
        esza etaa etaf etam etbe etdd etga etha etor etsi etsn~o etsw
        etti fi02~9 fi10~9 fj01~9 fj10~4 fjc fje fjn fjr fjw fmksa fmpni
        fmtrk fmyap fr01~9 fr10~9 fr20r fr21~9 fr2a~b fr30~9 fr40~9 fr50~9 fr60~9 fr69m
        fr6ae fr70~4 fr75c fr76~9 fr80~9 fr90~5 fr971~4 fr976 frara frbfc frbre frcvl
        frges frhdf fridf frnaq frnor frocc frpac frpdl ga1~9 gbabc~e gbagb gbagy
        gband gbann gbans gbbas gbbbd gbbcp gbbdf~g gbben gbbex gbbfs gbbge gbbgw
        gbbir gbbkm gbbne gbbnh gbbns gbbol gbbpl gbbrc~d gbbry gbbst gbbur gbcam
        gbcay gbcbf gbccg gbcgn gbche gbchw gbcld gbclk gbcma gbcmd gbcmn gbcon
        gbcov gbcrf gbcry gbcwy gbdal gbdby gbden gbder gbdev gbdgy gbdnc~d gbdor
        gbdrs gbdud gbdur gbeal gbeay gbedh gbedu gbeln gbels gbenf~g gberw gbery
        gbess gbesx gbfal gbfif gbfln gbfmo gbgat gbglg gbgls gbgre gbgwn gbhal~m
        gbhav gbhck gbhef gbhil gbhld gbhmf gbhns gbhpl gbhrt gbhrw gbhry gbios
        gbiow gbisl gbivc gbkec gbken gbkhl gbkir gbktt gbkwl gblan gblbc gblbh
        gblce gblds gblec gblew gblin gbliv gblnd gblut gbman gbmdb gbmdw gbmea
        gbmik gbmln gbmon gbmrt gbmry gbmty gbmul gbnay gbnbl gbnel gbnet gbnfk
        gbngm gbnir gbnlk gbnln gbnmd gbnnh gbnsm gbntl gbntt gbnty gbnwm gbnwp
        gbnyk gbold gbork gboxf gbpem gbpkn gbply gbpor gbpow gbpte gbrcc gbrch
        gbrct gbrdb gbrdg gbrfw gbric gbrot gbrut gbsaw gbsay gbscb gbsct gbsfk
        gbsft gbsgc gbshf gbshn gbshr gbskp gbslf~g gbslk gbsnd gbsol~m gbsos gbsry
        gbste gbstg~h gbstn gbsts~t gbsty gbswa gbswd gbswk gbtam gbtfw gbthr gbtob
        gbtof gbtrf gbtwh gbvgl gbwar gbwbk gbwdu gbwft gbwgn gbwil gbwkf gbwll
        gbwln gbwls gbwlv gbwnd gbwnh gbwnm gbwok gbwor gbwrl gbwrt gbwrx gbwsm
        gbwsx gbyor gbzet gd01~6 gd10 geab geaj gegu geim geka gekk gemm
        gerl gesj~k gesz getb ghaa ghaf ghah ghbe ghbo ghcp ghep ghne
        ghnp ghot ghsv ghtv ghue ghuw ghwn ghwp glav glku glqe glqt
        glsm gmb gml~n gmu gmw gnb gnbe~f gnbk gnc gnco gnd gndb
        gndi gndl gndu gnf gnfa gnfo gnfr gnga gngu gnk gnka~b gnkd~e
        gnkn~o gnks gnl gnla gnle gnlo gnm gnmc~d gnml~m gnn gnnz gnpi
        gnsi gnte gnto gnyo gqan gqbn gqbs gqc gqcs gqdj gqi gqkn
        gqli gqwn gr69 gra~m gt01~9 gt10~9 gt20~2 gwba gwbl~m gwbs gwca gwga
        gwl gwn gwoi gwqu gws gwto gyba gycu gyde gyeb gyes gyma
        gypm gypt gyud gyut hnat hnch hncl~m hncp hncr hnep hnfm hngd
        hnib hnin hnle hnlp hnoc hnol hnsb hnva hnyo hr01~9 hr10~9 hr20~1
        htar htce htga htnd~e htni htno htou htsd~e huba hubc hube hubk
        hubu hubz hucs hude hudu hueg huer hufe hugs hugy huhb huhe
        huhv hujn huke hukm hukv humi hunk huno huny hupe hups husd
        husf hush husk husn~o huss~t husz hutb huto huva huve huvm huza
        huze idac idba~b idbe idbt idgo idja~b idji idjk idjt idjw idka~b
        idki idkr~u idla idma idml idmu idnb idnt~u idpa~b idpd~e idpp idps~t
        idri idsa~b idsg idsl~n idsr~u idyo iec iece iecn~o iecw ied iedl
        ieg ieke iekk ieky iel ield ielh ielk ielm iels iem iemh
        iemn~o ieoy iern ieso ieta ieu iewd iewh ieww~x ild ilha iljm
        ilm ilta ilz inan inap inar~s inbr incg~h indh indl inga ingj
        inhp inhr injh injk inka inkl inla inld inmh inml inmn inmp
        inmz innl inod inpb inpy inrj insk intn intr~s inuk inup inwb
        iqan iqar iqba~b iqbg iqda iqdi iqdq iqka iqki iqkr iqma iqmu
        iqna iqni iqqa iqsd iqsu iqwa ir00~9 ir10~9 ir20~9 ir30 is1~8 isakn
        isaku isarn isasa isbla isbog isbol isdab isdav iseom iseyf isfjd isfjl
        isfla isflr isgar isgog isgrn isgru isgry ishaf ishrg ishru ishug ishuv
        ishva ishve isisa iskal iskjo iskop islan ismos ismul ismyr isnor isrge
        isrgy isrhh isrkn isrkv issbt issdn issdv issel issfa isshf isskf~g issko
        isskr issnf issog issol issss isstr issty issvg istal isthg istjo isvem
        isver isvop it21 it23 it25 it32 it34 it36 it42 it45 it52 it55
        it57 it62 it65 it67 it72 it75 it77~8 it82 it88 itag ital itan
        itap~r itat itav itba itbg itbi itbl itbn~o itbr~t itbz itca~b itce
        itch itcl itcn~o itcr~t itcz iten itfc itfe itfg itfi itfm itfr
        itge itgo itgr itim itis itkr itlc itle itli itlo itlt~u itmb~c
        itme itmi itmn~o itms~t itna itno itnu itor itpa itpc~e itpg itpi
        itpn~o itpr itpt~v itpz itra itrc itre itrg itri itrm~o itsa itsi
        itso~p itsr~s itsu~v itta itte ittn~p ittr~s ittv itud itva~c itve itvi
        itvr itvt itvv jm01~9 jm10~4 joaj joam joaq joat joaz joba joir
        joja joka joma jomd jomn jp01~9 jp10~9 jp20~9 jp30~9 jp40~7 ke01~9 ke10~9
        ke20~9 ke30~9 ke40~7 kgb~c kggb kggo kgj kgn~o kgt kgy kh1 kh10~9
        kh2 kh20~5 kh3~9 kig kil kip kma kmg kmm kn01~9 kn10~3 kn15
        knk knn kp01~9 kp10 kp13~5 kr11 kr26~9 kr30~1 kr41~9 kr50 kwah kwfa
        kwha kwja kwku kwmu kz10~1 kz15 kz19 kz23 kz27 kz31 kz33 kz35
        kz39 kz43 kz47 kz55 kz59 kz61~3 kz71 kz75 kz79 laat labk~l lach
        laho lakh lalm lalp laou laph lasl lasv lavi lavt laxa laxe
        laxi laxs lbak lbas lbba lbbh~i lbja lbjl lbna lc01~3 lc05~8 lc10~2
        li01~9 li10~1 lk1 lk11~3 lk2 lk21~3 lk3 lk31~3 lk4 lk41~5 lk5 lk51~3
        lk6 lk61~2 lk7 lk71~2 lk8 lk81~2 lk9 lk91~2 lrbg lrbm lrcm lrgb
        lrgg lrgk lrgp lrlo lrmg lrmo lrmy lrni lrrg lrri lrsi lsa~h
        lsj~k lt01~9 lt10~9 lt20~9 lt30~9 lt40~9 lt50~9 lt60 ltal ltkl ltku ltmr
        ltpn ltsa ltta ltte ltut ltvl luca lucl ludi luec lues lugr
        lulu lume lurd lurm luvd luwi lv002 lv007 lv011 lv015~6 lv022 lv026
        lv033 lv041~2 lv047 lv050 lv052 lv054 lv056 lv058~9 lv062 lv067~8 lv073 lv077
        lv080 lv087~9 lv091 lv094 lv097 lv099 lv101~2 lv106 lv111~3 lvdgv lvjel lvjur
        lvlpx lvrez lvrix lvven lyba lybu lydr lygt lyja lyjg lyji lyju
        lykf lymb lymi~j lymq lynl lynq lysb lysr lytb lywa lywd lyws
        lyza ma01~9 ma10~2 maagd maaou maasz maazi mabem maber~s mabod mabom mabrr
        macas mache machi macht madri maerr maesi maesm mafah mafes mafig mafqh
        mague~f mahaj mahao mahoc maifr maine majdi majra maken makes makhe makhn~o
        malaa malar mamar mamdf mamed mamek mamid mamoh mamou manad manou maoua
        maoud maouj maouz marab mareh masaf masal masef maset masib masif masik~l
        maskh mataf matai matao matar matat mataz matet matin matiz matng matnt
        mayus mazag mccl mcco mcfo mcga mcje mcla mcma mcmc mcmg mcmo
        mcmu mcph mcsd mcso~p mcsr mcvr mdan mdba mdbd mdbr~s mdca mdcl~m
        mdcr~u mddo mddr mddu mded mdfa mdfl mdga mdgl mdhi mdia mdle
        mdni mdoc mdor mdre mdri mdsd mdsi mdsn~o mdst mdsv mdta mdte
        mdun me01~9 me10~9 me20~5 mga mgd mgf mgm mgt~u mhalk~l mharn mhaur
        mhebo mheni mhjab mhjal mhkil mhkwa mhl mhlae mhlib mhlik mhmaj mhmal
        mhmej mhmil mhnmk mhnmu mhron mht mhuja mhuti mhwth mhwtj mk101~9 mk201~9
        mk210~1 mk301 mk303~4 mk307~8 mk310~3 mk401~9 mk410 mk501~9 mk601~9 mk701~6 mk801~9 mk810~7
        ml1 ml10 ml2~9 mlbko mm01~7 mm11~8 mn035 mn037 mn039 mn041 mn043 mn046~7
        mn049 mn051 mn053 mn055 mn057 mn059 mn061 mn063~5 mn067 mn069 mn071 mn073
        mn1 mr01~9 mr10~5 mt01~9 mt10~9 mt20~9 mt30~9 mt40~9 mt50~9 mt60~8 muag mubl
        mucc mufl mugp mumo mupa mupl mupw muro murr musa mv00~5 mv07~8
        mv12~4 mv17 mv20 mv23~9 mvmle mwba mwbl mwc mwck mwcr mwct mwde
        mwdo mwkr~s mwli mwlk mwmc mwmg~h mwmu mwmw mwmz mwn mwnb mwne
        mwni mwnk mwns mwnu mwph mwru mws mwsa mwth mwzo mxagu mxbcn
        mxbcs mxcam mxchh mxchp mxcmx mxcoa mxcol mxdur mxgro mxgua mxhid mxjal
        mxmex mxmic mxmor mxnay mxnle mxoax mxpue mxque mxroo mxsin mxslp mxson
        mxtab mxtam mxtla mxver mxyuc mxzac my01~9 my10~6 mza~b mzg mzi mzl
        mzmpm mzn mzp~q mzs~t naca naer naha naka nake nakh naku nakw
        naod naoh naon naos~t naow ne1~8 ngab ngad ngak ngan ngba ngbe
        ngbo ngby ngcr ngde ngeb nged ngek ngen ngfc nggo ngim ngji
        ngkd~e ngkn~o ngkt ngkw ngla ngna ngni ngog ngon ngos ngoy ngpl
        ngri ngso ngta ngyo ngza nian nias nibo nica nici nico nies
        nigr niji nile nimd nimn nims~t nins niri nisj nlbq1~3 nldr nlfl
        nlfr nlge nlgr nlli nlnb nlnh nlov nlut nlze nlzh no03 no11
        no15 no18 no21~2 no30 no34 no38 no42 no46 no50 no54 npp1~7 nr01~9
        nr10~4 nzauk nzbop nzcan nzcit nzgis nzhkb nzmbh nzmwt nznsn nzntl nzota
        nzstl nztas nztki nzwgn nzwko nzwtc ombj ombs ombu omda omma ommu
        omsj omss omwu omza omzu pa1 pa10 pa2~9 paem paky panb pant
        peama peanc peapu peare peaya pecaj pecal pecus pehuc pehuv peica pejun
        pelal~m pelim pelma pelor pemdd pemoq pepas pepiu pepun pesam petac petum
        peuca pgcpk pgcpm pgebr pgehg pgepw pgesw pggpk pghla pgjwk pgmba pgmpl~m
        pgmrl pgncd pgnik pgnpp pgnsb pgsan pgshm pgwbk pgwhm pgwpd ph00~3 ph05~9
        ph10~5 ph40~1 phabr phagn phags phakl phalb phant phapa phaur phban phbas
        phben phbil phboh phbtg phbtn phbuk~l phcag phcam~n phcap phcas~t phcav phceb
        phcom phdao phdas phdav phdin phdvo pheas phgui phifu phili philn phils
        phisa phkal phlag phlan phlas phley phlun phmad phmas phmdc phmdr phmgn
        phmgs phmou phmsc phmsr phnco phnec phner phnsa phnue phnuv phpam~n phplw
        phque phqui phriz phrom phsar phsco phsig phsle phslu phsor phsuk phsun
        phsur phtar phtaw phwsa phzan phzas phzmb phzsi pkba pkgb pkis pkjk
        pkkp pkpb pksd pl02 pl04 pl06 pl08 pl10 pl12 pl14 pl16 pl18
        pl20 pl22 pl24 pl26 pl28 pl30 pl32 psbth psdeb psgza pshbn psjem~n
        psjrh pskys psnbs psngz psqqa psrbh psrfh psslt pstbs pstkm pt01~9 pt10~8
        pt20 pt30 pw002 pw004 pw010 pw050 pw100 pw150 pw212 pw214 pw218 pw222
        pw224 pw226~8 pw350 pw370 py1 py10~6 py19 py2~9 pyasu qada qakh qams
        qara qash qaus qawa qaza roab roag roar rob robc robh robn
        robr robt robv robz rocj rocl rocs~t rocv rodb rodj rogj rogl
        rogr rohd rohr roif roil rois romh romm roms ront root roph
        rosb rosj rosm rosv rotl~m rotr rovl rovn rovs rs00~9 rs10~9 rs20~9
        rskm rsvo ruad rual rualt ruamu ruark ruast ruba rubel rubry rubu
        ruce ruche ruchu rucu ruda ruin ruirk ruiva rukam rukb~c rukda rukem
        rukgd rukgn rukha rukhm rukir rukk~l ruklu ruko rukos rukr rukrs rukya
        rulen rulip rumag rume rumo rumos rumow rumur runen rungr runiz runvs
        ruoms ruore ruorl ruper rupnz rupri rupsk ruros rurya rusa rusak rusam
        rusar ruse rusmo ruspe rusta rusve ruta rutam rutom rutul rutve ruty
        rutyu ruud ruuly ruvgg ruvla ruvlg ruvor ruyan ruyar ruyev ruzab rw01~5
        sa01~9 sa10~2 sa14 sbce sbch sbct sbgu sbis sbmk~l sbrb sbte sbwe
        sc01~9 sc10~9 sc20~7 sddc sdde sddn sdds sddw sdgd sdgk sdgz sdka
        sdkh sdkn sdks sdnb sdno sdnr sdnw sdrs sdsi seab~c sebd sec~i
        sek sem~o ses~u sew~z sg01~5 shac shhl si001~9 si010~9 si020~9 si030~9 si040~9
        si050~9 si060~9 si070~9 si080~9 si090~9 si100~9 si110~9 si120~9 si130~9 si140~4 si146~9 si150~9
        si160~9 si170~9 si180~9 si190~9 si200~9 si210~3 skbc skbl skki skni skpv skta
        sktc skzi sle sln slnw sls slw sm01~9 sndb sndk snfk snka
        snkd~e snkl snlg snmt snse snsl sntc snth snzg soaw sobk sobn
        sobr soby soga soge sohi sojd sojh somu sonu sosa sosd sosh
        soso soto sowo srbr srcm srcr srma srni srpm srpr srsa srsi
        srwa ssbn ssbw ssec ssee ssew ssjg sslk ssnu ssuy sswr st01~6
        stp svah svca svch svcu svli svmo svpa svsa svsm svso svss
        svsv svun svus sydi sydr sydy syha syhi syhl~m syid syla syqu
        syra syrd sysu syta szhh szlu szma szsh tdba tdbg tdbo tdcb
        tdee tdeo tdgr tdhl tdka tdlc tdlo tdlr tdma tdmc tdme tdmo
        tdnd tdod tdsa tdsi tdta tdti tdwf tgc tgk tgm tgp tgs
        th10~9 th20~7 th30~9 th40~9 th50~8 th60~7 th70~7 th80~6 th90~6 ths tjdu tjgb
        tjkt tjra tjsu tlal tlan tlba tlbo tlco tldi tler tlla tlli
        tlmf tlmt tloe tlvi tma~b tmd tml~m tms tn11~4 tn21~3 tn31~4 tn41~3
        tn51~3 tn61 tn71~3 tn81~3 to01~5 tr01~9 tr10~9 tr20~9 tr30~9 tr40~9 tr50~9 tr60~9
        tr70~9 tr80~1 ttari ttcha ttctt ttdmn ttmrc ttped ttpos ttprt ttptf ttsfo
        ttsge ttsip ttsjl tttob tttup tvfun tvnit tvnkf tvnkl tvnma tvnmg tvnui
        tvvai twcha twcyi twcyq twhsq twhsz twhua twila twkee twkhh twkin twlie
        twmia twnan twnwt twpen twpif twtao twtnn twtpe twttt twtxg twyun tz01~9
        tz10~9 tz20~9 tz30~1 ua05 ua07 ua09 ua12 ua14 ua18 ua21 ua23 ua26
        ua30 ua32 ua35 ua40 ua43 ua46 ua48 ua51 ua53 ua56 ua59 ua61
        ua63 ua65 ua68 ua71 ua74 ua77 ug101~9 ug110~9 ug120~6 ug201~9 ug210~9 ug220~9
        ug230~7 ug301~9 ug310~9 ug320~9 ug330~7 ug401~9 ug410~9 ug420~9 ug430~5 ugc uge ugn
        ugw um67 um71 um76 um79 um81 um84 um86 um89 um95 usak~l usar
        usaz usca usco usct usdc usde usfl usga ushi usia usid usil
        usin usks usky usla usma usmd~e usmi usmn~o usms~t usnc~e usnh usnj
        usnm usnv usny usoh usok usor uspa usri ussc~d ustn ustx usut
        usva usvt uswa uswi uswv uswy uyar uyca uycl uyco uydu uyfd
        uyfs uyla uyma uymo uypa uyrn~o uyrv uysa uysj uyso uyta uytt
        uzan uzbu uzfa uzji uzng uznw uzqa uzqr uzsa uzsi uzsu uztk
        uzto uzxo vc01~6 vea~p ver~z vn01~7 vn09 vn13~4 vn18 vn20~9 vn30~7 vn39
        vn40~1 vn43~7 vn49 vn50~9 vn61 vn63 vn66~9 vn70~3 vnct vndn vnhn vnhp
        vnsg vumap vupam vusam vusee vutae vutob wfal wfsg wfuv wsaa wsal
        wsat wsfa wsge wsgi wspa wssa wstu wsvf wsvs yeab yead yeam
        yeba yeda yedh yehd yehj yehu yeib yeja yela yema yemr yemw
        yera yesa yesd yesh yesn yesu yeta zaec zafs zagp zakzn zalp
        zamp zanc zanw zawc zm01~9 zm10 zwbu zwha zwma zwmc zwme zwmi
        zwmn zwms zwmv~w albr albu aldi aldl aldr aldv alel aler alfr
        algj algr alha alka~c alko alkr alku allb alle allu almk almm
        almr almt alpg alpq~r alpu alsh alsk alsr alte altp altr alvl
        ba01~9 ba10 bh16 cdbn cdka cdkw cdor ci01~9 ci10~9 cn11~5 cn21~3 cn31~7
        cn41~6 cn50~4 cn61~5 cn71 cn91~2 cz101~9 cz10a~f cz110~9 cz120~2 cz611~5 cz621~7 czjc
        czjm czka czkr czli czmo czol czpa czpl czpr czst czus czvy
        czzl ee44 ee49 ee51 ee57 ee59 ee65 ee67 ee70 ee78 ee82 ee86
        fi01 fr75 fra~b frbl frc frcor frcp frd~g frgf frgp frgua frh~l
        frlre frm frmay frmf frmq frn frnc fro~p frpf frpm frq~r frre
        frs~t frtf fru~v frwf fryt gbant gbard gbarm gbbla gbbly gbbmh gbbnb
        gbcgv gbckf gbckt gbclr gbcsr gbdgn gbdow gbdry gbeaw gbfer gbgbn gblmv
        gblrn gblsb gbmft gbmyl gbndn gbnta gbnth gbnym gbomh gbpol gbstb gbukm
        ghba glqa gr01 gr03~7 gr11~7 gr21~4 gr31~4 gr41~4 gr51~9 gr61~4 gr71~3 gr81~5
        gr91~4 gra1 gtav gtbv gtcm gtcq gtes gtgu gthu gtiz gtja gtju
        gtpe gtpr gtqc gtqz gtre gtsa gtsm gtso gtsr gtsu gtto gtza
        inct indd indn inor intg inut ir31~2 is0 isakh isbfj isblo isdju
        isfld ishel ishut issbh issey issku isssf itao itci itog itot itsd
        itvs kzakm kzakt kzala kzalm kzast kzaty kzbay kzkar kzkus kzkzy kzman
        kzpav kzsev kzshy kzvos kzyuz kzzap kzzha laxn lud lug lul lv001
        lv003~6 lv008~9 lv010 lv012~4 lv017~9 lv020~1 lv023~5 lv027~9 lv030~2 lv034~9 lv040 lv043~6
        lv048~9 lv051 lv053 lv055 lv057 lv060~1 lv063~6 lv069 lv070~2 lv074~6 lv078~9 lv081~6
        lv090 lv092~3 lv095~6 lv098 lv100 lv103~5 lv107~9 lv110 lvjkb lvvmr ma13~6 mammd
        mammn masyb mk01~9 mk10~9 mk20~9 mk30~9 mk40~9 mk50~9 mk60~9 mk70~9 mk80~5 mrnkc
        mubr mucu mupu muqb muvp mvce mvnc mvno mvsc mvsu mvun mvus
        mxdif nlaw nlcw nlsx no01~2 no04~9 no10 no12 no14 no16~7 no19 no20
        no23 np1~5 npba npbh npdh npga npja npka npko nplu npma npme
        npna npra npsa npse nzn nzs omba omsh phmag pkta plds plkp
        pllb plld pllu plma plmz plop plpd plpk plpm plsk~l plwn plwp
        plzp shta sts tteto ttrcm ttwto twkhq twtnq twtpq twtxq usas usgu
        usmp uspr usum usvi zagt zanl
        """

    private static let numericRegionTokenData = """
        001~3 005 009 011 013~5 017~9 021 029 030 034~5 039 053~4
        057 061 142~3 145 150~1 154~5 202 419
        """

    private static let registeredVariationSequenceKeys: [UInt32] = [
        0x0000023E, 0x0000023F, 0x000002AE, 0x000002AF, 0x00000300, 0x0000030E, 0x0000030F, 0x0000031E,
        0x0000031F, 0x0000032E, 0x0000032F, 0x0000033E, 0x0000033F, 0x0000034E, 0x0000034F, 0x0000035E,
        0x0000035F, 0x0000036E, 0x0000036F, 0x0000037E, 0x0000037F, 0x0000038E, 0x0000038F, 0x0000039E,
        0x0000039F, 0x00000A9E, 0x00000A9F, 0x00000AEE, 0x00000AEF, 0x00010000, 0x00010020, 0x00010040,
        0x00010100, 0x00010110, 0x00010150, 0x00010190, 0x000101A0, 0x000101C0, 0x000101D0, 0x00010220,
        0x00010310, 0x00010750, 0x00010780, 0x000107A0, 0x00010800, 0x00020180, 0x00020181, 0x00020182,
        0x00020190, 0x00020191, 0x00020192, 0x000201C0, 0x000201C1, 0x000201C2, 0x000201D0, 0x000201D1,
        0x000201D2, 0x000203CE, 0x000203CF, 0x0002049E, 0x0002049F, 0x000210B0, 0x000210B1, 0x00021100,
        0x00021101, 0x00021120, 0x00021121, 0x000211B0, 0x000211B1, 0x0002122E, 0x0002122F, 0x000212C0,
        0x000212C1, 0x00021300, 0x00021301, 0x00021310, 0x00021311, 0x00021330, 0x00021331, 0x0002139E,
        0x0002139F, 0x0002194E, 0x0002194F, 0x0002195E, 0x0002195F, 0x0002196E, 0x0002196F, 0x0002197E,
        0x0002197F, 0x0002198E, 0x0002198F, 0x0002199E, 0x0002199F, 0x00021A9E, 0x00021A9F, 0x00021AAE,
        0x00021AAF, 0x00022050, 0x00022290, 0x000222A0, 0x00022680, 0x00022690, 0x00022720, 0x00022730,
        0x000228A0, 0x000228B0, 0x00022930, 0x00022940, 0x00022950, 0x00022970, 0x000229C0, 0x00022DA0,
        0x00022DB0, 0x000231AE, 0x000231AF, 0x000231BE, 0x000231BF, 0x0002328E, 0x0002328F, 0x00023CFE,
        0x00023CFF, 0x00023E9E, 0x00023E9F, 0x00023EAE, 0x00023EAF, 0x00023EBE, 0x00023EBF, 0x00023ECE,
        0x00023ECF, 0x00023EDE, 0x00023EDF, 0x00023EEE, 0x00023EEF, 0x00023EFE, 0x00023EFF, 0x00023F0E,
        0x00023F0F, 0x00023F1E, 0x00023F1F, 0x00023F2E, 0x00023F2F, 0x00023F3E, 0x00023F3F, 0x00023F8E,
        0x00023F8F, 0x00023F9E, 0x00023F9F, 0x00023FAE, 0x00023FAF, 0x00024C2E, 0x00024C2F, 0x00025AAE,
        0x00025AAF, 0x00025ABE, 0x00025ABF, 0x00025B6E, 0x00025B6F, 0x00025C0E, 0x00025C0F, 0x00025FBE,
        0x00025FBF, 0x00025FCE, 0x00025FCF, 0x00025FDE, 0x00025FDF, 0x00025FEE, 0x00025FEF, 0x0002600E,
        0x0002600F, 0x0002601E, 0x0002601F, 0x0002602E, 0x0002602F, 0x0002603E, 0x0002603F, 0x0002604E,
        0x0002604F, 0x000260EE, 0x000260EF, 0x0002611E, 0x0002611F, 0x0002614E, 0x0002614F, 0x0002615E,
        0x0002615F, 0x0002618E, 0x0002618F, 0x000261DE, 0x000261DF, 0x0002620E, 0x0002620F, 0x0002622E,
        0x0002622F, 0x0002623E, 0x0002623F, 0x0002626E, 0x0002626F, 0x000262AE, 0x000262AF, 0x000262EE,
        0x000262EF, 0x000262FE, 0x000262FF, 0x0002638E, 0x0002638F, 0x0002639E, 0x0002639F, 0x000263AE,
        0x000263AF, 0x0002640E, 0x0002640F, 0x0002642E, 0x0002642F, 0x0002648E, 0x0002648F, 0x0002649E,
        0x0002649F, 0x000264AE, 0x000264AF, 0x000264BE, 0x000264BF, 0x000264CE, 0x000264CF, 0x000264DE,
        0x000264DF, 0x000264EE, 0x000264EF, 0x000264FE, 0x000264FF, 0x0002650E, 0x0002650F, 0x0002651E,
        0x0002651F, 0x0002652E, 0x0002652F, 0x0002653E, 0x0002653F, 0x000265FE, 0x000265FF, 0x0002660E,
        0x0002660F, 0x0002663E, 0x0002663F, 0x0002665E, 0x0002665F, 0x0002666E, 0x0002666F, 0x0002668E,
        0x0002668F, 0x000267BE, 0x000267BF, 0x000267EE, 0x000267EF, 0x000267FE, 0x000267FF, 0x0002692E,
        0x0002692F, 0x0002693E, 0x0002693F, 0x0002694E, 0x0002694F, 0x0002695E, 0x0002695F, 0x0002696E,
        0x0002696F, 0x0002697E, 0x0002697F, 0x0002699E, 0x0002699F, 0x000269BE, 0x000269BF, 0x000269CE,
        0x000269CF, 0x00026A0E, 0x00026A0F, 0x00026A1E, 0x00026A1F, 0x00026A7E, 0x00026A7F, 0x00026AAE,
        0x00026AAF, 0x00026ABE, 0x00026ABF, 0x00026B0E, 0x00026B0F, 0x00026B1E, 0x00026B1F, 0x00026BDE,
        0x00026BDF, 0x00026BEE, 0x00026BEF, 0x00026C4E, 0x00026C4F, 0x00026C5E, 0x00026C5F, 0x00026C8E,
        0x00026C8F, 0x00026CEE, 0x00026CEF, 0x00026CFE, 0x00026CFF, 0x00026D1E, 0x00026D1F, 0x00026D3E,
        0x00026D3F, 0x00026D4E, 0x00026D4F, 0x00026E9E, 0x00026E9F, 0x00026EAE, 0x00026EAF, 0x00026F0E,
        0x00026F0F, 0x00026F1E, 0x00026F1F, 0x00026F2E, 0x00026F2F, 0x00026F3E, 0x00026F3F, 0x00026F4E,
        0x00026F4F, 0x00026F5E, 0x00026F5F, 0x00026F7E, 0x00026F7F, 0x00026F8E, 0x00026F8F, 0x00026F9E,
        0x00026F9F, 0x00026FAE, 0x00026FAF, 0x00026FDE, 0x00026FDF, 0x0002702E, 0x0002702F, 0x0002705E,
        0x0002705F, 0x0002708E, 0x0002708F, 0x0002709E, 0x0002709F, 0x000270AE, 0x000270AF, 0x000270BE,
        0x000270BF, 0x000270CE, 0x000270CF, 0x000270DE, 0x000270DF, 0x000270FE, 0x000270FF, 0x0002712E,
        0x0002712F, 0x0002714E, 0x0002714F, 0x0002716E, 0x0002716F, 0x000271DE, 0x000271DF, 0x0002721E,
        0x0002721F, 0x0002728E, 0x0002728F, 0x0002733E, 0x0002733F, 0x0002734E, 0x0002734F, 0x0002744E,
        0x0002744F, 0x0002747E, 0x0002747F, 0x000274CE, 0x000274CF, 0x000274EE, 0x000274EF, 0x0002753E,
        0x0002753F, 0x0002754E, 0x0002754F, 0x0002755E, 0x0002755F, 0x0002757E, 0x0002757F, 0x0002763E,
        0x0002763F, 0x0002764E, 0x0002764F, 0x0002795E, 0x0002795F, 0x0002796E, 0x0002796F, 0x0002797E,
        0x0002797F, 0x00027A1E, 0x00027A1F, 0x00027B0E, 0x00027B0F, 0x00027BFE, 0x00027BFF, 0x0002934E,
        0x0002934F, 0x0002935E, 0x0002935F, 0x00029B70, 0x0002A3C0, 0x0002A3D0, 0x0002A9D0, 0x0002A9E0,
        0x0002AAC0, 0x0002AAD0, 0x0002ACB0, 0x0002ACC0, 0x0002B05E, 0x0002B05F, 0x0002B06E, 0x0002B06F,
        0x0002B07E, 0x0002B07F, 0x0002B1BE, 0x0002B1BF, 0x0002B1CE, 0x0002B1CF, 0x0002B50E, 0x0002B50F,
        0x0002B55E, 0x0002B55F, 0x00030010, 0x00030011, 0x00030020, 0x00030021, 0x0003030E, 0x0003030F,
        0x000303DE, 0x000303DF, 0x0003297E, 0x0003297F, 0x0003299E, 0x0003299F, 0x000349E0, 0x00034B90,
        0x00034BB0, 0x00034DF0, 0x00035150, 0x00036EE0, 0x00036FC0, 0x00037810, 0x000382F0, 0x00038620,
        0x000387C0, 0x00038C70, 0x00038E30, 0x000391C0, 0x000393A0, 0x0003A2E0, 0x0003A6C0, 0x0003AE40,
        0x0003B080, 0x0003B190, 0x0003B490, 0x0003B9D0, 0x0003B9D1, 0x0003C180, 0x0003C4E0, 0x0003D330,
        0x0003D960, 0x0003EAC0, 0x0003EB80, 0x0003EB81, 0x0003F1B0, 0x0003FFC0, 0x00040080, 0x00040180,
        0x00040390, 0x00040391, 0x00040460, 0x00040960, 0x00040E30, 0x000412F0, 0x00042020, 0x00042270,
        0x00042A00, 0x00043010, 0x00043340, 0x00043590, 0x00043D50, 0x00043D90, 0x000440B0, 0x000446B0,
        0x000452B0, 0x000455D0, 0x00045610, 0x000456B0, 0x00045D70, 0x00045F90, 0x00046350, 0x00046BE0,
        0x00046C70, 0x00049950, 0x00049E60, 0x0004A6E0, 0x0004A760, 0x0004AB20, 0x0004B330, 0x0004BCE0,
        0x0004CCE0, 0x0004CED0, 0x0004CF80, 0x0004D560, 0x0004E0D0, 0x0004E260, 0x0004E320, 0x0004E380,
        0x0004E390, 0x0004E3D0, 0x0004E410, 0x0004E820, 0x0004E860, 0x0004EAE0, 0x0004EC00, 0x0004ECC0,
        0x0004EE40, 0x0004F600, 0x0004F800, 0x0004F860, 0x0004F8B0, 0x0004FAE0, 0x0004FAE1, 0x0004FBB0,
        0x0004FBF0, 0x00050020, 0x000502B0, 0x000507A0, 0x00050990, 0x00050CF0, 0x00050DA0, 0x00050E70,
        0x00050E71, 0x00051400, 0x00051450, 0x000514D0, 0x000514D1, 0x00051540, 0x00051640, 0x00051670,
        0x00051680, 0x00051690, 0x000516D0, 0x00051770, 0x00051800, 0x000518D0, 0x00051920, 0x00051950,
        0x00051970, 0x00051A40, 0x00051AC0, 0x00051B50, 0x00051B51, 0x00051B70, 0x00051C90, 0x00051CC0,
        0x00051DC0, 0x00051DE0, 0x00051F50, 0x00052030, 0x00052070, 0x00052071, 0x00052170, 0x00052290,
        0x000523A0, 0x000523B0, 0x00052460, 0x00052720, 0x00052770, 0x00052890, 0x000529B0, 0x00052A30,
        0x00052B30, 0x00052C70, 0x00052C71, 0x00052C90, 0x00052C91, 0x00052D20, 0x00052DE0, 0x00052E40,
        0x00052E41, 0x00052F50, 0x00052FA0, 0x00052FA1, 0x00053050, 0x00053060, 0x00053170, 0x00053171,
        0x000533F0, 0x00053490, 0x00053510, 0x00053511, 0x000535A0, 0x00053730, 0x00053750, 0x000537D0,
        0x000537F0, 0x000537F1, 0x000537F2, 0x00053C30, 0x00053CA0, 0x00053DF0, 0x00053E50, 0x00053EB0,
        0x00053F10, 0x00054060, 0x000540F0, 0x000541D0, 0x00054380, 0x00054420, 0x00054480, 0x00054680,
        0x000549E0, 0x00054A20, 0x00054BD0, 0x00054F60, 0x00055100, 0x00055530, 0x00055550, 0x00055630,
        0x00055840, 0x00055841, 0x00055870, 0x00055990, 0x00055991, 0x000559D0, 0x000559D1, 0x00055AB0,
        0x00055B30, 0x00055C00, 0x00055C20, 0x00055E20, 0x00056060, 0x00056061, 0x00056510, 0x00056680,
        0x00056740, 0x00056F90, 0x00057160, 0x00057170, 0x000578B0, 0x00057CE0, 0x00057F40, 0x000580D0,
        0x00058310, 0x00058320, 0x00058400, 0x000585A0, 0x000585A1, 0x000585E0, 0x00058A80, 0x00058AC0,
        0x00058B30, 0x00058D80, 0x00058DF0, 0x00058EE0, 0x00058F20, 0x00058F70, 0x00059060, 0x000591A0,
        0x00059220, 0x00059440, 0x00059480, 0x00059510, 0x00059540, 0x00059620, 0x00059730, 0x00059D80,
        0x00059EC0, 0x0005A1B0, 0x0005A270, 0x0005A620, 0x0005A660, 0x0005AB50, 0x0005B080, 0x0005B280,
        0x0005B3E0, 0x0005B3E1, 0x0005B850, 0x0005BC30, 0x0005BD80, 0x0005BE70, 0x0005BE71, 0x0005BE72,
        0x0005BEE0, 0x0005BF30, 0x0005BFF0, 0x0005C060, 0x0005C220, 0x0005C3F0, 0x0005C600, 0x0005C620,
        0x0005C640, 0x0005C650, 0x0005C6E0, 0x0005C6E1, 0x0005C8D0, 0x0005CC00, 0x0005D190, 0x0005D430,
        0x0005D500, 0x0005D6B0, 0x0005D6E0, 0x0005D7C0, 0x0005DB20, 0x0005DBA0, 0x0005DE10, 0x0005DE20,
        0x0005DFD0, 0x0005E280, 0x0005E3D0, 0x0005E690, 0x0005E740, 0x0005EA60, 0x0005EB00, 0x0005EB30,
        0x0005EB60, 0x0005EC90, 0x0005ECA0, 0x0005ECA1, 0x0005ED20, 0x0005ED30, 0x0005ED90, 0x0005EEC0,
        0x0005EFE0, 0x0005F040, 0x0005F220, 0x0005F221, 0x0005F530, 0x0005F620, 0x0005F690, 0x0005F6B0,
        0x0005F8B0, 0x0005F9A0, 0x0005FA90, 0x0005FAD0, 0x0005FCD0, 0x0005FD70, 0x0005FF50, 0x0005FF90,
        0x00060120, 0x000601C0, 0x00060750, 0x00060810, 0x00060940, 0x00060941, 0x00060C70, 0x00060D80,
        0x00060E10, 0x00061080, 0x00061440, 0x00061480, 0x000614C0, 0x000614C1, 0x000614E0, 0x000614E1,
        0x00061600, 0x00061680, 0x000617A0, 0x000618E0, 0x000618E1, 0x000618E2, 0x00061900, 0x00061A40,
        0x00061AF0, 0x00061B20, 0x00061DE0, 0x00061F20, 0x00061F21, 0x00061F22, 0x00061F60, 0x00061F61,
        0x00062000, 0x00062100, 0x000621B0, 0x000622E0, 0x00062340, 0x000625D0, 0x00062B10, 0x00062C90,
        0x00062CF0, 0x00062D30, 0x00062D40, 0x00062FC0, 0x00062FE0, 0x000633D0, 0x00063500, 0x00063680,
        0x000637B0, 0x00063830, 0x00063A00, 0x00063A90, 0x00063C40, 0x00063C50, 0x00063E40, 0x000641C0,
        0x00064220, 0x00064520, 0x00064690, 0x00064770, 0x000647E0, 0x000649A0, 0x000649D0, 0x00064C40,
        0x000654F0, 0x000654F1, 0x00065560, 0x000656C0, 0x00065780, 0x00065990, 0x00065C50, 0x00065E20,
        0x00065E30, 0x00066130, 0x00066490, 0x00066740, 0x00066741, 0x00066880, 0x00066910, 0x00066911,
        0x000669C0, 0x00066B40, 0x00066C60, 0x00066F40, 0x00066F80, 0x00067000, 0x00067170, 0x00067171,
        0x00067172, 0x000671B0, 0x000671B1, 0x00067210, 0x000674E0, 0x00067530, 0x00067560, 0x000675E0,
        0x000677B0, 0x00067850, 0x00067970, 0x00067F30, 0x00067FA0, 0x00068170, 0x000681F0, 0x00068520,
        0x00068810, 0x00068850, 0x00068851, 0x000688E0, 0x00068A80, 0x00069140, 0x00069420, 0x00069A30,
        0x00069EA0, 0x0006A020, 0x0006A021, 0x0006A022, 0x0006A130, 0x0006AA80, 0x0006AD30, 0x0006ADB0,
        0x0006B040, 0x0006B210, 0x0006B540, 0x0006B720, 0x0006B770, 0x0006B790, 0x0006B9F0, 0x0006BAE0,
        0x0006BBA0, 0x0006BBA1, 0x0006BBA2, 0x0006BBB0, 0x0006C4E0, 0x0006C670, 0x0006C880, 0x0006CBF0,
        0x0006CCC0, 0x0006CCD0, 0x0006CE50, 0x0006D160, 0x0006D1B0, 0x0006D1E0, 0x0006D340, 0x0006D3E0,
        0x0006D410, 0x0006D411, 0x0006D412, 0x0006D690, 0x0006D6A0, 0x0006D770, 0x0006D771, 0x0006D780,
        0x0006D850, 0x0006DCB0, 0x0006DDA0, 0x0006DEA0, 0x0006DF90, 0x0006E1A0, 0x0006E2F0, 0x0006E6E0,
        0x0006E9C0, 0x0006EBA0, 0x0006EC70, 0x0006ECB0, 0x0006ECB1, 0x0006ED10, 0x0006EDB0, 0x0006F0F0,
        0x0006F220, 0x0006F221, 0x0006F230, 0x0006F6E0, 0x0006FC60, 0x0006FEB0, 0x0006FFE0, 0x000701B0,
        0x000701E0, 0x000701E1, 0x00070390, 0x000704A0, 0x00070700, 0x00070770, 0x000707D0, 0x00070990,
        0x00070AD0, 0x00070C80, 0x00070D90, 0x00071450, 0x00071490, 0x000716E0, 0x000716E1, 0x000719C0,
        0x00071CE0, 0x00071D00, 0x00072100, 0x000721B0, 0x00072280, 0x000722B0, 0x00072350, 0x00072351,
        0x00072500, 0x00072620, 0x00072800, 0x00072950, 0x00072AF0, 0x00072C00, 0x00072FC0, 0x000732A0,
        0x000732A1, 0x00073750, 0x000737A0, 0x00073870, 0x00073871, 0x000738B0, 0x00073A50, 0x00073B20,
        0x00073DE0, 0x00074060, 0x00074090, 0x00074220, 0x00074470, 0x000745C0, 0x00074690, 0x00074710,
        0x00074711, 0x00074850, 0x00074890, 0x00074980, 0x00074CA0, 0x00075060, 0x00075240, 0x000753B0,
        0x000753E0, 0x00075590, 0x00075650, 0x00075700, 0x00075701, 0x00075E20, 0x00076100, 0x000761D0,
        0x000761F0, 0x00076420, 0x00076690, 0x00076CA0, 0x00076CA1, 0x00076DB0, 0x00076E70, 0x00076F40,
        0x00076F41, 0x00077010, 0x000771E0, 0x000771F0, 0x000771F1, 0x00077400, 0x000774A0, 0x000774A1,
        0x000778B0, 0x00077A70, 0x000784E0, 0x000786B0, 0x000788C0, 0x000788C1, 0x00078910, 0x00078CA0,
        0x00078CC0, 0x00078CC1, 0x00078FB0, 0x000792A0, 0x000793C0, 0x000793E0, 0x00079480, 0x00079490,
        0x00079500, 0x00079560, 0x00079561, 0x000795D0, 0x000795E0, 0x00079650, 0x000797F0, 0x000798D0,
        0x000798E0, 0x000798F0, 0x000798F1, 0x00079AE0, 0x00079CA0, 0x00079EB0, 0x0007A1C0, 0x0007A400,
        0x0007A401, 0x0007A4A0, 0x0007A4F0, 0x0007A810, 0x0007AB10, 0x0007ACB0, 0x0007AEE0, 0x0007B200,
        0x0007BC00, 0x0007BC01, 0x0007BC60, 0x0007BC90, 0x0007C3E0, 0x0007C600, 0x0007C7B0, 0x0007C920,
        0x0007CBE0, 0x0007CD20, 0x0007CD60, 0x0007CE30, 0x0007CE70, 0x0007CE80, 0x0007D000, 0x0007D100,
        0x0007D220, 0x0007D2F0, 0x0007D5B0, 0x0007D630, 0x0007DA00, 0x0007DBE0, 0x0007DC70, 0x0007DF40,
        0x0007DF41, 0x0007DF42, 0x0007E020, 0x0007E090, 0x0007E370, 0x0007E410, 0x0007E450, 0x0007F3E0,
        0x0007F720, 0x0007F790, 0x0007F7A0, 0x0007F850, 0x0007F950, 0x0007F9A0, 0x0007FBD0, 0x0007FFA0,
        0x00080010, 0x00080050, 0x00080051, 0x00080052, 0x00080460, 0x00080600, 0x000806F0, 0x00080700,
        0x000807E0, 0x000808B0, 0x00080AD0, 0x00080B20, 0x00081030, 0x000813E0, 0x00081D80, 0x00081E80,
        0x00081ED0, 0x00082010, 0x00082011, 0x00082040, 0x00082180, 0x000826F0, 0x00082790, 0x00082791,
        0x000828B0, 0x00082910, 0x000829D0, 0x00082B10, 0x00082B30, 0x00082BD0, 0x00082E50, 0x00082E51,
        0x00082E60, 0x000831D0, 0x00083230, 0x00083360, 0x00083520, 0x00083530, 0x00083630, 0x00083AD0,
        0x00083BD0, 0x00083C90, 0x00083CA0, 0x00083CC0, 0x00083DC0, 0x00083E70, 0x00083EF0, 0x00083F10,
        0x000843D0, 0x00084490, 0x00084570, 0x00084571, 0x00084EE0, 0x00084F10, 0x00084F30, 0x00084FC0,
        0x00085160, 0x00085640, 0x00085CD0, 0x00085FA0, 0x00086060, 0x00086120, 0x000862D0, 0x000863F0,
        0x00086500, 0x000865C0, 0x000865C1, 0x00086670, 0x00086690, 0x00086880, 0x00086A90, 0x00086E20,
        0x000870E0, 0x00087280, 0x000876B0, 0x00087790, 0x00087791, 0x00087860, 0x00087BA0, 0x00087E10,
        0x00088010, 0x000881F0, 0x000884C0, 0x00088600, 0x00088630, 0x00088C20, 0x00088CF0, 0x00088D70,
        0x00088DE0, 0x00088E10, 0x00088F80, 0x00088FA0, 0x00089100, 0x00089410, 0x00089640, 0x00089860,
        0x000898B0, 0x00089960, 0x00089961, 0x0008AA00, 0x0008AAA0, 0x0008AAA1, 0x0008ABF0, 0x0008ACB0,
        0x0008AD20, 0x0008AD60, 0x0008AED0, 0x0008AED1, 0x0008AF80, 0x0008AF81, 0x0008AFE0, 0x0008AFE1,
        0x0008B010, 0x0008B011, 0x0008B390, 0x0008B391, 0x0008B580, 0x0008B800, 0x0008B8A0, 0x0008B8A1,
        0x0008C480, 0x0008C550, 0x0008CAB0, 0x0008CC10, 0x0008CC20, 0x0008CC80, 0x0008CD30, 0x0008D080,
        0x0008D081, 0x0008D1B0, 0x0008D770, 0x0008DBC0, 0x0008DCB0, 0x0008DEF0, 0x0008DF00, 0x0008ECA0,
        0x0008ED40, 0x0008F260, 0x0008F2A0, 0x0008F380, 0x0008F381, 0x0008F3B0, 0x0008F620, 0x0008F9E0,
        0x0008FB00, 0x0008FB60, 0x00090230, 0x00090380, 0x00090381, 0x00090720, 0x000907C0, 0x000908F0,
        0x00090940, 0x00090CE0, 0x00090DE0, 0x00090F10, 0x00090FD0, 0x00091110, 0x000911B0, 0x000916A0,
        0x00091990, 0x00091B40, 0x00091CC0, 0x00091CF0, 0x00091D10, 0x00092340, 0x00092380, 0x00092760,
        0x000927C0, 0x00092D70, 0x00092D80, 0x00093040, 0x000934A0, 0x00093F90, 0x00094150, 0x000958B0,
        0x00095AD0, 0x00095B70, 0x000962E0, 0x000964B0, 0x000964D0, 0x00096750, 0x00096780, 0x000967C0,
        0x00096860, 0x00096A30, 0x00096B70, 0x00096B80, 0x00096C30, 0x00096E20, 0x00096E30, 0x00096E31,
        0x00096F60, 0x00096F70, 0x00097230, 0x00097320, 0x00097480, 0x00097560, 0x00097561, 0x00097DB0,
        0x00097E00, 0x00097FF0, 0x00097FF1, 0x000980B0, 0x000980B1, 0x000980B2, 0x00098180, 0x00098290,
        0x000983B0, 0x000983B1, 0x000985E0, 0x00098E20, 0x00098EF0, 0x00098FC0, 0x00099280, 0x00099290,
        0x00099A70, 0x00099C20, 0x00099F10, 0x00099FE0, 0x0009A6A0, 0x0009B120, 0x0009B121, 0x0009B6F0,
        0x0009C400, 0x0009C570, 0x0009CFD0, 0x0009D670, 0x0009DB40, 0x0009DFA0, 0x0009E1E0, 0x0009E7F0,
        0x0009E970, 0x0009E9F0, 0x0009EBB0, 0x0009ECE0, 0x0009EF90, 0x0009EFE0, 0x0009F050, 0x0009F0F0,
        0x0009F160, 0x0009F3B0, 0x0009F430, 0x0009F8D0, 0x0009F8E0, 0x0009F9C0, 0x0009F9C1, 0x0009F9C2,
        0x000A8560, 0x000A85C0, 0x000A85E0, 0x000A85F0, 0x000A8600, 0x000A8680, 0x000AA600, 0x000AA610,
        0x000AA620, 0x000AA630, 0x000AA640, 0x000AA650, 0x000AA660, 0x000AA6B0, 0x000AA6C0, 0x000AA6F0,
        0x000AA7A0, 0x000FF010, 0x000FF011, 0x000FF0C0, 0x000FF0C1, 0x000FF0E0, 0x000FF0E1, 0x000FF100,
        0x000FF1A0, 0x000FF1A1, 0x000FF1B0, 0x000FF1B1, 0x000FF1F0, 0x000FF1F1, 0x0010AC50, 0x0010AC60,
        0x0010AD60, 0x0010AD70, 0x0010AE10, 0x00130123, 0x00130910, 0x00130931, 0x00130B83, 0x00130BA3,
        0x001310F0, 0x001310F3, 0x00131172, 0x001311C0, 0x00131210, 0x00131270, 0x001312F3, 0x001312F6,
        0x00131321, 0x00131390, 0x00131391, 0x00131392, 0x00131393, 0x00131394, 0x00131395, 0x00131396,
        0x00131832, 0x00131843, 0x00131846, 0x00131871, 0x001319C3, 0x001319D3, 0x001319F3, 0x00131A00,
        0x00131A02, 0x00131B10, 0x00131B11, 0x00131B13, 0x00131B80, 0x00131B90, 0x00131BA2, 0x00131CB0,
        0x00131DB3, 0x00131DB6, 0x00131E00, 0x00131EE1, 0x00131EE2, 0x00131EE6, 0x00131F81, 0x00131F90,
        0x00131F91, 0x00131FA0, 0x00131FA1, 0x00132053, 0x00132056, 0x00132162, 0x00132571, 0x001327B0,
        0x001327B2, 0x001327F0, 0x001327F1, 0x00132850, 0x001328B1, 0x001328C0, 0x00132963, 0x00132A41,
        0x00132A42, 0x00132A46, 0x00132AA0, 0x00132CB0, 0x00132DC0, 0x00132E70, 0x00132E72, 0x00132E92,
        0x00132E96, 0x00132F82, 0x00132FD2, 0x00133022, 0x00133032, 0x00133070, 0x00133081, 0x00133102,
        0x00133112, 0x00133121, 0x00133122, 0x00133131, 0x00133132, 0x00133141, 0x00133142, 0x001331B0,
        0x001331B1, 0x001331C2, 0x00133211, 0x00133212, 0x00133220, 0x00133221, 0x001332B6, 0x00133311,
        0x00133312, 0x00133383, 0x00133386, 0x001333C0, 0x001334A2, 0x00133612, 0x00133706, 0x00133716,
        0x00133732, 0x00133770, 0x00133780, 0x001337D2, 0x00133852, 0x00133990, 0x001339A0, 0x00133AF2,
        0x00133B02, 0x00133BF2, 0x00133D30, 0x00133DB2, 0x00133DD2, 0x00133E40, 0x00133E50, 0x00133E70,
        0x00133E81, 0x00133EE0, 0x00133F20, 0x00133F50, 0x00133F60, 0x001340D4, 0x00134160, 0x00134190,
        0x00134191, 0x00134192, 0x00134193, 0x00134196, 0x001341A0, 0x00134230, 0x001342C2, 0x001342E2,
        0x00134430, 0x00134440, 0x00134450, 0x00134460, 0x0013BE80, 0x0013BE90, 0x0013BEA0, 0x0013F1F1,
        0x0013F720, 0x00142741, 0x00142742, 0x00142745, 0x00142746, 0x001D49C0, 0x001D49C1, 0x001D49E0,
        0x001D49E1, 0x001D49F0, 0x001D49F1, 0x001D4A20, 0x001D4A21, 0x001D4A50, 0x001D4A51, 0x001D4A60,
        0x001D4A61, 0x001D4A90, 0x001D4A91, 0x001D4AA0, 0x001D4AA1, 0x001D4AB0, 0x001D4AB1, 0x001D4AC0,
        0x001D4AC1, 0x001D4AE0, 0x001D4AE1, 0x001D4AF0, 0x001D4AF1, 0x001D4B00, 0x001D4B01, 0x001D4B10,
        0x001D4B11, 0x001D4B20, 0x001D4B21, 0x001D4B30, 0x001D4B31, 0x001D4B40, 0x001D4B41, 0x001D4B50,
        0x001D4B51, 0x001F004E, 0x001F004F, 0x001F170E, 0x001F170F, 0x001F171E, 0x001F171F, 0x001F17EE,
        0x001F17EF, 0x001F17FE, 0x001F17FF, 0x001F202E, 0x001F202F, 0x001F21AE, 0x001F21AF, 0x001F22FE,
        0x001F22FF, 0x001F237E, 0x001F237F, 0x001F30DE, 0x001F30DF, 0x001F30EE, 0x001F30EF, 0x001F30FE,
        0x001F30FF, 0x001F315E, 0x001F315F, 0x001F31CE, 0x001F31CF, 0x001F321E, 0x001F321F, 0x001F324E,
        0x001F324F, 0x001F325E, 0x001F325F, 0x001F326E, 0x001F326F, 0x001F327E, 0x001F327F, 0x001F328E,
        0x001F328F, 0x001F329E, 0x001F329F, 0x001F32AE, 0x001F32AF, 0x001F32BE, 0x001F32BF, 0x001F32CE,
        0x001F32CF, 0x001F336E, 0x001F336F, 0x001F378E, 0x001F378F, 0x001F37DE, 0x001F37DF, 0x001F393E,
        0x001F393F, 0x001F396E, 0x001F396F, 0x001F397E, 0x001F397F, 0x001F399E, 0x001F399F, 0x001F39AE,
        0x001F39AF, 0x001F39BE, 0x001F39BF, 0x001F39EE, 0x001F39EF, 0x001F39FE, 0x001F39FF, 0x001F3A7E,
        0x001F3A7F, 0x001F3ACE, 0x001F3ACF, 0x001F3ADE, 0x001F3ADF, 0x001F3AEE, 0x001F3AEF, 0x001F3C2E,
        0x001F3C2F, 0x001F3C4E, 0x001F3C4F, 0x001F3C6E, 0x001F3C6F, 0x001F3CAE, 0x001F3CAF, 0x001F3CBE,
        0x001F3CBF, 0x001F3CCE, 0x001F3CCF, 0x001F3CDE, 0x001F3CDF, 0x001F3CEE, 0x001F3CEF, 0x001F3D4E,
        0x001F3D4F, 0x001F3D5E, 0x001F3D5F, 0x001F3D6E, 0x001F3D6F, 0x001F3D7E, 0x001F3D7F, 0x001F3D8E,
        0x001F3D8F, 0x001F3D9E, 0x001F3D9F, 0x001F3DAE, 0x001F3DAF, 0x001F3DBE, 0x001F3DBF, 0x001F3DCE,
        0x001F3DCF, 0x001F3DDE, 0x001F3DDF, 0x001F3DEE, 0x001F3DEF, 0x001F3DFE, 0x001F3DFF, 0x001F3E0E,
        0x001F3E0F, 0x001F3EDE, 0x001F3EDF, 0x001F3F3E, 0x001F3F3F, 0x001F3F5E, 0x001F3F5F, 0x001F3F7E,
        0x001F3F7F, 0x001F408E, 0x001F408F, 0x001F415E, 0x001F415F, 0x001F41FE, 0x001F41FF, 0x001F426E,
        0x001F426F, 0x001F43FE, 0x001F43FF, 0x001F441E, 0x001F441F, 0x001F442E, 0x001F442F, 0x001F446E,
        0x001F446F, 0x001F447E, 0x001F447F, 0x001F448E, 0x001F448F, 0x001F449E, 0x001F449F, 0x001F44DE,
        0x001F44DF, 0x001F44EE, 0x001F44EF, 0x001F453E, 0x001F453F, 0x001F46AE, 0x001F46AF, 0x001F47DE,
        0x001F47DF, 0x001F4A3E, 0x001F4A3F, 0x001F4B0E, 0x001F4B0F, 0x001F4B3E, 0x001F4B3F, 0x001F4BBE,
        0x001F4BBF, 0x001F4BFE, 0x001F4BFF, 0x001F4CBE, 0x001F4CBF, 0x001F4DAE, 0x001F4DAF, 0x001F4DFE,
        0x001F4DFF, 0x001F4E4E, 0x001F4E4F, 0x001F4E5E, 0x001F4E5F, 0x001F4E6E, 0x001F4E6F, 0x001F4EAE,
        0x001F4EAF, 0x001F4EBE, 0x001F4EBF, 0x001F4ECE, 0x001F4ECF, 0x001F4EDE, 0x001F4EDF, 0x001F4F7E,
        0x001F4F7F, 0x001F4F9E, 0x001F4F9F, 0x001F4FAE, 0x001F4FAF, 0x001F4FBE, 0x001F4FBF, 0x001F4FDE,
        0x001F4FDF, 0x001F508E, 0x001F508F, 0x001F50DE, 0x001F50DF, 0x001F512E, 0x001F512F, 0x001F513E,
        0x001F513F, 0x001F549E, 0x001F549F, 0x001F54AE, 0x001F54AF, 0x001F550E, 0x001F550F, 0x001F551E,
        0x001F551F, 0x001F552E, 0x001F552F, 0x001F553E, 0x001F553F, 0x001F554E, 0x001F554F, 0x001F555E,
        0x001F555F, 0x001F556E, 0x001F556F, 0x001F557E, 0x001F557F, 0x001F558E, 0x001F558F, 0x001F559E,
        0x001F559F, 0x001F55AE, 0x001F55AF, 0x001F55BE, 0x001F55BF, 0x001F55CE, 0x001F55CF, 0x001F55DE,
        0x001F55DF, 0x001F55EE, 0x001F55EF, 0x001F55FE, 0x001F55FF, 0x001F560E, 0x001F560F, 0x001F561E,
        0x001F561F, 0x001F562E, 0x001F562F, 0x001F563E, 0x001F563F, 0x001F564E, 0x001F564F, 0x001F565E,
        0x001F565F, 0x001F566E, 0x001F566F, 0x001F567E, 0x001F567F, 0x001F56FE, 0x001F56FF, 0x001F570E,
        0x001F570F, 0x001F573E, 0x001F573F, 0x001F574E, 0x001F574F, 0x001F575E, 0x001F575F, 0x001F576E,
        0x001F576F, 0x001F577E, 0x001F577F, 0x001F578E, 0x001F578F, 0x001F579E, 0x001F579F, 0x001F587E,
        0x001F587F, 0x001F58AE, 0x001F58AF, 0x001F58BE, 0x001F58BF, 0x001F58CE, 0x001F58CF, 0x001F58DE,
        0x001F58DF, 0x001F590E, 0x001F590F, 0x001F5A5E, 0x001F5A5F, 0x001F5A8E, 0x001F5A8F, 0x001F5B1E,
        0x001F5B1F, 0x001F5B2E, 0x001F5B2F, 0x001F5BCE, 0x001F5BCF, 0x001F5C2E, 0x001F5C2F, 0x001F5C3E,
        0x001F5C3F, 0x001F5C4E, 0x001F5C4F, 0x001F5D1E, 0x001F5D1F, 0x001F5D2E, 0x001F5D2F, 0x001F5D3E,
        0x001F5D3F, 0x001F5DCE, 0x001F5DCF, 0x001F5DDE, 0x001F5DDF, 0x001F5DEE, 0x001F5DEF, 0x001F5E1E,
        0x001F5E1F, 0x001F5E3E, 0x001F5E3F, 0x001F5E8E, 0x001F5E8F, 0x001F5EFE, 0x001F5EFF, 0x001F5F3E,
        0x001F5F3F, 0x001F5FAE, 0x001F5FAF, 0x001F610E, 0x001F610F, 0x001F687E, 0x001F687F, 0x001F68DE,
        0x001F68DF, 0x001F691E, 0x001F691F, 0x001F694E, 0x001F694F, 0x001F698E, 0x001F698F, 0x001F6ADE,
        0x001F6ADF, 0x001F6B2E, 0x001F6B2F, 0x001F6B9E, 0x001F6B9F, 0x001F6BAE, 0x001F6BAF, 0x001F6BCE,
        0x001F6BCF, 0x001F6CBE, 0x001F6CBF, 0x001F6CDE, 0x001F6CDF, 0x001F6CEE, 0x001F6CEF, 0x001F6CFE,
        0x001F6CFF, 0x001F6E0E, 0x001F6E0F, 0x001F6E1E, 0x001F6E1F, 0x001F6E2E, 0x001F6E2F, 0x001F6E3E,
        0x001F6E3F, 0x001F6E4E, 0x001F6E4F, 0x001F6E5E, 0x001F6E5F, 0x001F6E9E, 0x001F6E9F, 0x001F6F0E,
        0x001F6F0F, 0x001F6F3E, 0x001F6F3F, 0x00201220, 0x002051C0, 0x00205250, 0x002054B0, 0x002063A0,
        0x00208040, 0x00208DE0, 0x0020A2C0, 0x0020B630, 0x00214E40, 0x00216A80, 0x00216EA0, 0x00219C80,
        0x0021B180, 0x0021D0B0, 0x0021DE40, 0x0021DE60, 0x00221830, 0x002219F0, 0x00223310, 0x00223311,
        0x00226D40, 0x00228440, 0x002284A0, 0x0022B0C0, 0x0022BF10, 0x002300A0, 0x00232B80, 0x002335F0,
        0x00233930, 0x002339C0, 0x00233C30, 0x00233D50, 0x002346D0, 0x00236A30, 0x00238A70, 0x0023A8D0,
        0x0023AFA0, 0x0023CBC0, 0x0023D1E0, 0x0023ED10, 0x0023F5E0, 0x0023F8E0, 0x00242630, 0x00242EE0,
        0x00243AB0, 0x00246080, 0x00247350, 0x00248140, 0x0024C360, 0x0024C920, 0x0024FA10, 0x0024FB80,
        0x00250440, 0x00250F20, 0x00250F30, 0x00251190, 0x00251330, 0x00252490, 0x002541D0, 0x00256260,
        0x002569A0, 0x00256C50, 0x002597C0, 0x0025AA70, 0x0025AA71, 0x0025BAB0, 0x0025C800, 0x0025CD00,
        0x0025F860, 0x00261DA0, 0x00262280, 0x00262470, 0x00262D90, 0x002633E0, 0x00264DA0, 0x00265230,
        0x00265A80, 0x00267A70, 0x00267B50, 0x0026B3C0, 0x0026C360, 0x0026CD50, 0x0026D6B0, 0x0026F2C0,
        0x0026FB10, 0x00270D20, 0x00273CA0, 0x00276670, 0x00278AE0, 0x00279660, 0x0027CA80, 0x0027ED30,
        0x0027F2F0, 0x00285D20, 0x00285ED0, 0x002872E0, 0x0028BFA0, 0x0028D770, 0x00291450, 0x00291DF0,
        0x002921A0, 0x002940A0, 0x00294960, 0x00295B60, 0x0029B300, 0x002A0CE0, 0x002A1050, 0x002A20E0,
        0x002A2910, 0x002A3920, 0x002A6000,
    ]
}
