import Foundation

/// Source-labelled reference pitches, not a complete modal practice or
/// an authorization to send MIDI. Finite fragments never repeat implicitly.
public struct WorldTuningPreset: Equatable, Sendable, Identifiable {
    public enum Kind:String,Sendable {case theoretical,approximation,researchPrototype,documentedSample,mathematical}
    public enum Region:String,CaseIterable,Sendable {
        case turkish="Turkish / Ottoman",persian="Iranian / Persian",levant="Levant / Arabic"
        case byzantine="Byzantine",europe="Historical European",asia="Asia",africa="Africa",americas="Americas",experimental="Mathematical / experimental"
    }
    public let id:String
    public let name:String
    public let region:Region
    public let kind:Kind
    /// Includes zero. Excludes repeated octave endpoint for periodic
    /// models, includes every documented point for finite samples.
    public let cents:[Double]
    public let octavePeriodic:Bool
    public let source:String
    public let note:String

    public func tuning(rootMIDI:Int=60,referenceA4:Double=440)->MicrotonalKeyboardTuning? {
        guard octavePeriodic else{return nil}
        return .init(degrees:cents,rootMIDI:rootMIDI,referenceA4:referenceA4)
    }
}

public enum WorldTuningLibrary {
    private typealias P=WorldTuningPreset
    private static let panteli="Maria Panteli (2011), Table 2.3 p.26 / Table 2.2 p.23, https://mpanteli.github.io/pubs/thesis_2011.pdf"
    private static let abdoli="Sajjad Abdoli (2011), ISMIR, Table 1 p.276, https://ismir2011.ismir.net/papers/PS2-18.pdf"
    private static let maqam="https://www.maqamworld.com/en/maqam.php ; https://www.yedidmusic.com/maqamat"
    private static let archive="https://www.huygens-fokker.org/microtonality/scales.html"
    private static let damusc="McBride, Passmore, Tlusty (2023), DaMuSc, https://doi.org/10.1371/journal.pone.0284851 ; "
    private static func make(_ id:String,_ name:String,_ region:P.Region,_ kind:P.Kind,_ cents:[Double],_ source:String,_ note:String,periodic:Bool=true)->P {
        .init(id:id,name:name,region:region,kind:kind,cents:cents,octavePeriodic:periodic,source:source,note:note)
    }
    private static func steps(_ steps:[Int],divisions:Int)->[Double] {
        var sum=0
        return steps.map{step in
            let c=1200*Double(sum)/Double(divisions)
            sum+=step
            return c
        }
    }
    private static func tr(_ id:String,_ name:String,_ intervals:[Int],_ note:String="Fixed theoretical pitch collection; seyir and intonation vary.")->P {
        make("tr."+id,name,.turkish,.theoretical,steps(intervals,divisions:53),panteli,note)
    }
    private static func ir(_ id:String,_ name:String,_ cents:[Double])->P {
        make("ir."+id,name,.persian,.researchPrototype,cents,abdoli,"Published classification prototype, not a definitive radif tuning or fixed performance intonation.")
    }
    private static func ar(_ id:String,_ name:String,_ cents:[Double],_ note:String="Idealized 24-EDO pitch collection; local ajnas and performance intonation vary.")->P {
        make("ar."+id,name,.levant,.approximation,cents,maqam,note)
    }
    private static func byz(_ id:String,_ name:String,_ intervals:[Int])->P {
        make("byz."+id,name,.byzantine,.theoretical,steps(intervals,divisions:72),panteli,"Reference interval model; chant genre, attraction and melodic course matter.")
    }
    private static func ratio(_ n:Double,_ d:Double)->Double {1200*log2(n/d)}
    private static func fifthChain(_ fifth:Double)->[Double] {
        (-5...6).map{n in
            let raw=Double(n)*fifth
            return raw-floor(raw/1200)*1200
        }.sorted()
    }

    public static let presets:[WorldTuningPreset] = [
        tr("rast","Rast · 53-comma",[9,8,5,9,9,8,5]),
        tr("ussak","Uşşak · 53-comma",[8,5,9,9,4,9,9],"Theoretical second degree; lower in some melodic contexts. See https://islamansiklopedisi.org.tr/ussak"),
        tr("huseyni","Hüseynî · 53-comma",[8,5,9,9,8,5,9]),
        tr("buselik","Bûselik · 53-comma",[9,4,9,9,4,9,9]),
        tr("nihavend","Nihâvend · 53-comma",[9,4,9,9,4,9,9]),
        tr("hicaz-a","Hicaz · variant A",[5,12,5,9,4,9,9]),
        tr("hicaz-b","Hicaz · variant B",[5,12,5,9,8,5,9]),
        tr("hicazkar","Hicazkâr · 53-comma",[5,12,5,9,5,12,5]),
        tr("sedaraban","Şedaraban · 53-comma",[5,12,5,9,5,12,5]),
        tr("suzidil","Sûzidil · 53-comma",[5,13,4,9,5,12,5]),
        tr("suzinak","Sûzinak · 53-comma",[9,8,5,9,5,12,5]),
        tr("segah-a","Segâh · variant A",[5,9,8,9,5,9,8]),
        tr("segah-b","Segâh · variant B",[5,9,8,9,5,13,4]),
        tr("kurdilihicazkar","Kürdîlihicazkâr · 53-comma",[4,9,9,9,4,9,9]),
        make("tr.saba","Sabâ · finite reference",.turkish,.theoretical,[0,8,13,18,31,35,44,49].map{1200*Double($0)/53},panteli,"Non-octave sequence in Table 2.3; no implicit octave repetition.",periodic:false),
        ir("shur","Šur / Shur",[0,149,300,500,702,783,985]),
        ir("nava","Navā",[0,149,300,500,702,783,985]),
        ir("segah","Segāh",[0,198,352,495,707,826,1013]),
        ir("chahargah","Čahārgāh",[0,134,397,497,634,888,994]),
        ir("homayun","Homāyun",[0,100,398,502,715,800,990]),
        ir("mahur","Māhur",[0,208,397,497,702,891,994]),
        ir("rast-panjgah","Rāst-Panjgāh",[0,208,397,497,702,891,994]),
        ar("rast","Rast · 24-EDO model",[0,200,350,500,700,900,1050]),
        ar("bayati","Bayati · 24-EDO model",[0,150,300,500,700,800,1000]),
        ar("hijaz","Hijaz · 24-EDO model",[0,100,400,500,700,800,1000]),
        ar("kurd","Kurd · 24-EDO model",[0,100,300,500,700,800,1000]),
        ar("nahawand","Nahawand · lower Nahawand / upper Hijaz model",[0,200,300,500,700,800,1100]),
        ar("ajam","Ajam · major-like model",[0,200,400,500,700,900,1100]),
        make("ar.jins-sikah","Jins Sikah · fragment",.levant,.approximation,[0,150,350],maqam,"Trichord relative to its own tonic; not a full maqam.",periodic:false),
        make("ar.jins-saba","Jins Saba · fragment",.levant,.approximation,[0,150,300,400],maqam,"Tetrachord relative to its own tonic; not a full octave scale.",periodic:false),
        byz("first","First echos",[10,8,12,12,10,8,12]),
        byz("first-plagal","First plagal echos",[10,8,12,12,10,8,12]),
        byz("second","Second echos",[8,14,8,12,8,14,8]),
        byz("second-plagal","Second plagal echos",[6,20,4,12,6,20,4]),
        byz("third","Third echos",[12,12,6,12,12,12,6]),
        byz("grave","Grave echos · Papadika",[8,12,10,12,8,16,6]),
        byz("fourth","Fourth echos · Eirmologika",[8,12,12,10,8,12,10]),
        byz("fourth-plagal","Fourth plagal echos",[12,10,8,12,12,10,8]),
        make("eu.pythagorean","Pythagorean · fifth chain",.europe,.mathematical,fifthChain(ratio(3,2)),archive,"Twelve pitches from fifths -5 through +6; one chosen spelling."),
        make("eu.meantone-quarter","Quarter-comma meantone",.europe,.mathematical,fifthChain(ratio(3,2)-ratio(81,80)/4),archive,"Twelve pitches, fifth narrowed by one quarter syntonic comma; spelling matters."),
        make("eu.meantone-third","Third-comma meantone",.europe,.mathematical,fifthChain(ratio(3,2)-ratio(81,80)/3),archive,"Twelve pitches, fifth narrowed by one third syntonic comma; spelling matters."),
        make("eu.ji-major","5-limit just major",.europe,.mathematical,[0,ratio(9,8),ratio(5,4),ratio(4,3),ratio(3,2),ratio(5,3),ratio(15,8)],archive,"One explicit ratio choice; not all historical just scales."),
        make("asia.thai-7","Thai seven-equal model",.asia,.approximation,(0..<7).map{1200*Double($0)/7},"https://journals.sagepub.com/doi/10.1177/2059204318802505","Idealized equal-step model, not a measurement of all Thai ensembles."),
        make("asia.slendro-m0001","Sléndro 1 · recorded reference",.asia,.documentedSample,[0,263,486,739,975],damusc+"M0001 https://scalelibrary.org/scales/damusc/Indonesia_Slendro_01_a/","One documented collection; not a universal gamelan tuning."),
        make("asia.pelog-m0002","Pélog 1 · recorded reference",.asia,.documentedSample,[0,167,412,537,683,935,1100],damusc+"M0002 https://scalelibrary.org/scales/damusc/Indonesia_Pelog_01_a/","One documented collection; ensemble-specific tuning."),
        make("africa.likembe-m0196","Angola · Chisende 10618",.africa,.documentedSample,[0,149,361,538,674,851],damusc+"M0196 https://doi.org/10.21504/amj.v6i1.1097","Instrument-specific measurement; first pitch used as reference, not asserted tonic."),
        make("americas.bolivia-m0045","Bolivia · Panpipe 1",.americas,.documentedSample,[0,326,742,1046,1382,1739,2108,2394],damusc+"M0045 https://scalelibrary.org/scales/damusc/Bolivia_Panpipe_01/","Finite measured range; 2394 cents is not assumed to be an octave or repeat period.",periodic:false),
        make("americas.brazil-m0154","Brazil · Pífano",.americas,.documentedSample,[0,180,350,590,810,1000,1120,1300],damusc+"M0154 https://scalelibrary.org/scales/damusc/Brazil_Pifano/","Finite documented range; 1300 cents is not assumed to be a repeat period.",periodic:false)
    ] + [5,7,12,17,19,22,24,31,36,41,53,60,72,96,128].map{count in
        make("edo."+String(count),"\(count)-EDO",.experimental,.mathematical,(0..<count).map{1200*Double($0)/Double(count)},archive,"Equal octave division; not a cultural tuning claim.")
    }

    public static func preset(id:String)->WorldTuningPreset? {presets.first{$0.id==id}}
}
