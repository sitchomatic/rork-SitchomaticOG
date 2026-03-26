import Foundation

@MainActor
class PPSREmailRotationService {
    static let shared = PPSREmailRotationService()

    private var currentIndex: Int = 0
    private let storageKey = "email_csv_list_v1"

    private static let hardcodedEmails: [String] = [
        "aaaroger@aol.com", "aatireswheels@att.net", "abcloser03@gmail.com",
        "accesscellular@mail.com", "acholeka@aol.com", "acsryan@gmail.com",
        "adturne28@yahoo.com", "aekgddd@yahoo.com", "affordableautowv@yahoo.com",
        "africankoko@gmail.com", "ahammett10@yahoo.com", "akemikitahara@msn.com",
        "al.boatright@diversifiedfinancialconsulting.com", "alconnolly@firstrateaccounting.com",
        "alex@internets.net", "alexwatsonjr@sbcglobal.net", "aliciajiggetts@yahoo.com",
        "alkem1@aol.com", "allthlatcools@gmail.com", "alphonsomcdow@yahoo.com",
        "amensoliman@yahoo.com", "ameritex@usbdmail.com", "amlandscape@frii.com",
        "amweiss@globalwater.com", "andrewthomas@twinportssurveillance.com",
        "angel@threesixtyincometaxservices.com", "anime_inu_youkai@yahoo.com",
        "anitadn@aol.com", "ankurbhai@yahoo.com", "anmp20@yahoo.com",
        "anthony@financialinfobroker.com", "aricher@aol.com", "armandoponds1854@gmail.com",
        "armen_sar@yahoo.com", "arroyo.80@hotmail.com", "associateswaste@mail.com",
        "atasteofpleasure47@gmail.com", "atmmoney.guy@gmail.com", "atsmed6@aol.com",
        "atxsecurity@gmail.com", "atymes@gmail.com", "au2inc@yahoo.com",
        "avatarfin@hotmail.com", "awjchart@aol.com", "aylowinc@gmail.com",
        "ballinmagazine2000@yahoo.com", "bankscleaningservicesinc@gmail.com",
        "bartson.weaver@gmail.com", "beerman@copper.net", "bender909@yahoo.com",
        "benjamin.rocha@ey.com", "besimi76@hotmail.com", "bettyscountryflowers@gmail.com",
        "bhsupermfg@aol.com", "bill7@jps.net", "billcliver@gmail.com",
        "blazetransport@aol.com", "blenhinton@gmail.com", "bobbmessy@gmail.com",
        "bocaplumbing@bellsouth.net", "borichama@gmail.com", "brian.mcdonald@ymail.com",
        "brinksvw@aol.com", "bronx10466@live.com", "bsce99@gmail.com",
        "btminc@aol.com", "buffordexcavating@yahoo.com", "builderbrown9@yahoo.com",
        "burnscell@gmail.com", "capitalwa@aol.com", "ccdacoop607@gmail.com",
        "ccqnaz@gmail.com", "cdrsydorsey@bellsouth.net", "centeq89@yahoo.com",
        "chad@delogen.com", "chandra3737@sbcglobal.net", "chelly2245@yahoo.com",
        "clark@blsystems.org", "clarksservices@sbcglobal.net", "clecklercapital@gmail.com",
        "cochiesefilms@gmail.com", "colorfulassets@yahoo.com", "contact@omniuniversal.net",
        "countrycorners@ymail.com", "cr8ivassign@gmail.com", "crowdersauto@yahoo.com",
        "cupcakelovemiami@yahoo.com", "d.wise.wisllc@gmail.com", "dacinvests@gmail.com",
        "daliresearch2000@aol.com", "damon@hollawayplumbing.net", "darkhawkcycles@aol.com",
        "darrellwood1@gmail.com", "davidg@dmginsurance.net", "dbartho911@yahoo.com",
        "ddoug100@yahoo.com", "denniskv@hotmail.com", "deporterjr@gmail.com",
        "designershui@yahoo.com", "devoneastwood@yahoo.com", "dianasites@aol.com",
        "dianna.harvey@gmail.com", "dominick3764@aol.com", "dpriest8@hotmail.com",
        "drtim68@gmail.com", "dwall@yahoo.com", "easleytravel@yahoo.com",
        "eddiecontreraz@me.com", "eel501@aol.com", "elitetvl@att.net",
        "emailallinfo@aol.com", "emily@absoluteaccountingonline.com",
        "emmanueloso@bellsouth.net", "erobertson562662@yahoo.com", "ewrmfs@aol.com",
        "fantasychamp49@aol.com", "franbuerman@gmail.com", "francisco@fco-sccc.com",
        "frankriley@groveemail.com", "frostpatty@ymail.com", "futureguru100@gmail.com",
        "gail@onehourtees.com", "gary.frederics@gmail.com", "garybroadwell@aol.com",
        "geminimarine@gmail.com", "george@ioncorandd.com", "georgelbond@bellsouth.net",
        "ggravalis63@yahoo.com", "globalstatusonline@gmail.com", "gloria@atlaswt.com",
        "goldstarbaby@comcast.net", "greystoneequipment@gmail.com", "gthom300@gmail.com",
        "guardianwealthmgmt@gmail.com", "haircaresalon@gmail.com", "henry@henryrosa.com",
        "hitzoneent@gmail.com", "honeydon@suddenlink.com", "imbroimbro@aol.com",
        "inbox@afallc.org", "info@mehdeh.com", "info@spanzy.com",
        "innovative1realestatesolutions@gmail.com", "ira@youmanageyourmoney.com",
        "isaac3974@hotmail.com", "jahrome20@yahoo.com", "jamesmagnum717@hotmail.com",
        "jannie.brod@gmail.com", "jason82983@gmail.com", "jasongordon251@gmail.com",
        "jayventurelli@gmail.com", "jb@boggspartners.com", "jbherna44@yahoo.com",
        "jbr91275@gmail.com", "jdelacruz@gmail.com", "jeff@pssid.com",
        "jeff@rentbearcreek.com", "jehu@kp7hawaii.com", "jessemise@aol.com",
        "jgarrett@thegbelt.com", "jim.milton@cbnorcal.com", "jimbobgpe@gmail.com",
        "jmeak6@gmail.com", "jmeljr@yahoo.com", "joebuscemi1@yahoo.com",
        "john@randcroofinginc.com", "johnmaynard27@yahoo.com", "jonathan.wtf@me.com",
        "josallers@cambhanover.com", "jsholleman@cox.net", "jwashington@integrityconstruction.org",
        "jwestcapital@gmail.com", "kasell@live.com", "kathy.thehairdresser@gmail.com",
        "kennethdaniel2004@hotmail.com", "kennysimmons01@gmail.com", "kevingatlin@gmail.com",
        "kgray@grps.us", "kieth@onspot.com", "kingdavid28205@yahoo.com",
        "kit@svmx.com", "knightmvp@aol.com", "kristina@thelifeimaginedonline.com",
        "ladycsalon1@aol.com", "ladydentist1@sbcglobal.net", "landry@efinancing-solutions.com",
        "legendz@ptd.net", "letsgosocial@gmail.com", "lfritz413@aol.com",
        "lincolninn@gmail.com", "lindsey@silverspooncaters.net", "liquidautobody@yahoo.com",
        "loansbyjimmy@yahoo.com", "lorenzosimmons@msn.com", "lribanez@hotmail.com",
        "mac30260@yahoo.com", "mainstreetdiner1@aol.com", "mandee2979@me.com",
        "marcel@daquay.com", "marcoquezada@msn.com", "marcus@gatorfund.com",
        "matt6019@sbcglobal.net", "matthewlaycock21@gmail.com", "mbeasley@beasleyfinancialgroup.com",
        "mdowlutmd@aol.com", "meanallc@yahoo.com", "michael@montelaurovineyards.com",
        "michaelboetjer@aol.com", "mike@cplenders.com", "mikecaof@gmail.com",
        "mitchellparfait@att.net", "mmcgovern@insourcecredit.com", "moore.jim66@yahoo.com",
        "morrisinsurance@sbcglobal.net", "mr0070001@gmail.com", "msingh.miglani@gmail.com",
        "mwilks66@gmail.com", "nazik2697@aol.com", "newmans2424@yahoo.com",
        "nobletaxsolutions@gmail.com", "oakwoodhomesdevelopment@gmail.com",
        "ousman.nd@gmail.com", "paradiselots@hotmail.com", "pat@rusticridgehospitality.com",
        "paulaj2007@yahoo.com", "perry.ward@yahoo.com", "pete@alliedfi.com",
        "pgtravel@mail.com", "philip.davis@yahoo.com", "priority26@live.com",
        "pstorti@gmail.com", "quicksteven1@yahoo.com", "r.dickenson@yahoo.com",
        "rahsaanjrobinson@gmail.com", "raiderreg@aol.com", "ralphkelsun@aol.com",
        "rasched63@yahoo.com", "rbabineaux@manuspec.net", "rduese@afacompany.com",
        "realbiz1@netzero.com", "richardasummers@yahoo.com", "rick.galindo@yahoo.com",
        "rlittletrucking@aol.com", "rmartinez83@cox.net", "robertmdoherty@yahoo.com",
        "ron.frager@ix.netcom.com", "ronabdella@gmail.com", "rosiecthomas@cableone.net",
        "rsmall@smallsalessolutions.com", "ryan@ensowinery.com", "sales@3gorillasmoving.org",
        "sales@creativedatanetworks.com", "sanders12008@yahoo.com", "scott@prohealthins.com",
        "sean@codybrewing.com", "seanbrunsk@aol.com", "services@gandintel.com",
        "sgpappas@yahoo.com", "shawnmreed67@aol.com", "shieldedsolution@gmail.com",
        "signaturelight@aol.com", "slade52@yahoo.com", "smalito@gmail.com",
        "soliselectric@aol.com", "sp@purdyinsulation.com", "sronkoske@gmail.com",
        "ssbinvestment@sbcglobal.net", "staceefrane@gmail.com", "stange3@aol.com",
        "steve.clute@leadergized.com", "steve@4cable.tv", "stevebrian2@bellsouth.net",
        "sundancebeef@aol.com", "support@thomasliquidators.net", "sylvias3867@gmail.com",
        "tackettcpa@yahoo.com", "ted@prbeg.com", "theperkinsgroup@yahoo.com",
        "tigerlwyr@aol.com", "tim@copycentertoo.com", "tkbinv@yahoo.com",
        "todd@cleansoil.biz", "tommyduran@sbcglobal.net", "tonyc@affinity5.net",
        "topgearllc@yahoo.com", "triunegreg@yahoo.com", "trobi042277@yahoo.com",
        "twysong2003@yahoo.com", "upscaleinc@gmail.com", "ushermorgan@gmail.com",
        "vargasramon@yahoo.com", "vegasvic89121@gmail.com", "vic@polskisausage.com",
        "vickiecoats@bellsouth.net", "virtual1stop@gmail.com", "vivianatseb@gmail.com",
        "vrrickcarlson@gmail.com", "wctheiss@hotmail.com", "wiseike@hotmail.com",
        "woodville2182@gmail.com", "wtaiwo@aol.com", "xavier.orellana@live.com",
        "younces@yahoo.com", "youngflo84@hotmail.com", "younggroup@netzero.com",
        "ywanda@live.com", "zsoltalberti@yahoo.com"
    ]

    var emails: [String] = [] {
        didSet {
            UserDefaults.standard.set(emails, forKey: storageKey)
        }
    }

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: storageKey) ?? []
        if saved.isEmpty {
            emails = Self.hardcodedEmails
        } else {
            emails = saved
        }
    }

    func nextEmail() -> String? {
        guard !emails.isEmpty else { return nil }
        let email = emails[currentIndex % emails.count]
        currentIndex += 1
        return email
    }

    func importFromCSV(_ text: String) -> Int {
        let lines = text
            .components(separatedBy: CharacterSet.newlines.union(.init(charactersIn: ",")))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.contains("@") }

        let unique = Array(Set(lines))
        emails = unique
        currentIndex = 0
        return unique.count
    }

    func resetToDefault() {
        emails = Self.hardcodedEmails
        currentIndex = 0
    }

    func clear() {
        emails.removeAll()
        currentIndex = 0
    }

    var count: Int { emails.count }
    var hasEmails: Bool { !emails.isEmpty }
}
