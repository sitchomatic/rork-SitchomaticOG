import Foundation
import Observation

struct BillerBlacklistEntry: Identifiable, Sendable {
    let id: String
    let billerCode: String
    let reason: String
    let blacklistedAt: Date

    init(id: String = UUID().uuidString, billerCode: String, reason: String, blacklistedAt: Date = Date()) {
        self.id = id
        self.billerCode = billerCode
        self.reason = reason
        self.blacklistedAt = blacklistedAt
    }

    var formattedDate: String {
        DateFormatters.mediumDateTime.string(from: blacklistedAt)
    }
}

@Observable
@MainActor
class BPointBillerPoolService {
    static let shared = BPointBillerPoolService()

    private(set) var blacklistedBillers: [BillerBlacklistEntry] = []
    private var blacklistedCodes: Set<String> = []

    private let storageKey = "bpoint_biller_blacklist_v1"
    private let logger = DebugLogger.shared

    static let billerLookupURL = URL(string: "https://www.bpoint.com.au/payments/billpayment/Payment/Index")!

    var totalBillerCount: Int { Self.allBillerCodes.count }
    var blacklistedCount: Int { blacklistedBillers.count }
    var activeBillerCount: Int { totalBillerCount - blacklistedCount }
    var poolExhausted: Bool { activeBillerCount == 0 }

    var poolHealthPercentage: Double {
        guard totalBillerCount > 0 else { return 0 }
        return Double(activeBillerCount) / Double(totalBillerCount) * 100
    }

    init() {
        loadBlacklist()
    }

    func getRandomActiveBiller() -> String? {
        let active = Self.allBillerCodes.filter { !blacklistedCodes.contains($0) }
        return active.randomElement()
    }

    func getRandomActiveBillers(count: Int) -> [String] {
        let active = Self.allBillerCodes.filter { !blacklistedCodes.contains($0) }.shuffled()
        return Array(active.prefix(count))
    }

    func isBlacklisted(_ code: String) -> Bool {
        blacklistedCodes.contains(code)
    }

    func blacklistBiller(code: String, reason: String) {
        guard !blacklistedCodes.contains(code) else { return }
        blacklistedCodes.insert(code)
        let entry = BillerBlacklistEntry(billerCode: code, reason: reason)
        blacklistedBillers.insert(entry, at: 0)
        persistBlacklist()
        logger.log("BPoint pool: blacklisted biller \(code) — \(reason)", category: .ppsr, level: .warning)
    }

    func restoreBiller(_ entry: BillerBlacklistEntry) {
        blacklistedCodes.remove(entry.billerCode)
        blacklistedBillers.removeAll { $0.id == entry.id }
        persistBlacklist()
    }

    func resetPool() {
        blacklistedCodes.removeAll()
        blacklistedBillers.removeAll()
        persistBlacklist()
        logger.log("BPoint pool: RESET — all \(totalBillerCount) billers restored", category: .ppsr, level: .info)
    }

    func exportBlacklist() -> String {
        blacklistedBillers.map { "\($0.billerCode)|\($0.reason)" }.joined(separator: "\n")
    }

    func importBlacklist(_ text: String) {
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var imported = 0
        for line in lines {
            let parts = line.components(separatedBy: "|")
            let code = parts[0].trimmingCharacters(in: .whitespaces)
            let reason = parts.count > 1 ? parts[1] : "Imported"
            guard !code.isEmpty, !blacklistedCodes.contains(code) else { continue }
            blacklistedCodes.insert(code)
            blacklistedBillers.insert(BillerBlacklistEntry(billerCode: code, reason: reason), at: 0)
            imported += 1
        }
        if imported > 0 { persistBlacklist() }
    }

    private func persistBlacklist() {
        let encoded = blacklistedBillers.map { entry -> [String: Any] in
            [
                "id": entry.id,
                "code": entry.billerCode,
                "reason": entry.reason,
                "ts": entry.blacklistedAt.timeIntervalSince1970,
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: encoded) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadBlacklist() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        blacklistedBillers = array.compactMap { dict in
            guard let code = dict["code"] as? String else { return nil }
            let id = dict["id"] as? String ?? UUID().uuidString
            let reason = dict["reason"] as? String ?? ""
            let ts = dict["ts"] as? TimeInterval ?? Date().timeIntervalSince1970
            return BillerBlacklistEntry(id: id, billerCode: code, reason: reason, blacklistedAt: Date(timeIntervalSince1970: ts))
        }
        blacklistedCodes = Set(blacklistedBillers.map(\.billerCode))
    }

    private static let billerPrefix = "100"

    private static let billerSuffixes: [Int] = [
        1020,1015,1008,1003,1005,1002,1001,  56,   0,   1,
           9,1036,1032,1031,1029,1026,1045,1042,1033,1040,
        1039,1014,1007,1051,1072,1058,1069,1034,1057,1052,
        1047,1044,1030,1082,1093,1089,1068,1060,1083,1053,
        1081,1059,1079,1078,1116,1117,1076,1111,1107,1112,
        1088,1096,1085,1095,1090,1167,1175,1179,1173,1160,
        1148,1143,1166,1161,1152,1193,1203,1199,1204,1201,
        1197,1190,1196,1176,1189,1185,1207,1202,1208,1210,
        1200,1209,1227,1229,1226,1219,1224,1220,1217,1214,
        1216,1186,1250,1233,1242,1241,1236,1187,1237,1211,
        1234,1232,1274,1259,1267,1254,1264,1238,1256,1243,
        1252,1287,1285,1280,1235,1277,1245,1278,1275,1305,
        1302,1293,1296,1272,1271,1291,1292,1309,1326,1312,
        1311,1298,1308,1307,1346,1338,1340,1303,1322,1327,
        1320,1334,1328,1321,1366,1337,1349,1357,1360,1359,
        1351,1350,1331,1335,1398,1393,1368,1389,1386,1380,
        1385,1379,1314,1374,1404,1414,1411,1361,1403,1409,
        1408,1406,1405,1399,1412,1419,1420,1417,1413,1465,
        1457,1453,1458,1435,1449,1439,1442,1444,1438,1433,
        1485,1488,1480,1427,1474,1459,1467,1507,1503,1499,
        1494,1496,1533,1539,1538,1536,1531,1537,1529,1528,
        1504,1514,1517,1555,1530,1554,1549,1553,1585,1582,
        1579,1574,1569,1571,1566,1567,1543,1620,1619,1584,
        1616,1609,1612,1606,1605,1598,1565,1593,1659,1645,
        1638,1647,1646,1637,1628,1636,1641,1600,1686,1679,
        1677,1685,1682,1674,1662,1676,1670,1671,1667,1695,
        1713,1712,1699,1683,1708,1707,1656,1687,1697,1745,
        1757,1752,1750,1715,1739,1736,1733,1735,1738,1728,
        1786,1773,1784,1774,1755,1769,1771,1768,1767,1758,
        1766,1812,1810,1801,1811,1794,1798,1800,1796,1799,
        1789,1797,1839,1842,1841,1837,1833,1827,1832,1825,
        1815,1821,1823,1868,1873,1870,1849,1822,1857,1862,
        1866,1859,1856,1860,1898,1899,1895,1900,1892,1890,
        1888,1887,1867,1881,1879,1924,1913,1919,1920,1917,
        1907,1915,1911,1906,1897,1951,1941,1946,1949,1942,
        1944,1943,1937,1938,1936,1854,1954,1971,1962,1959,
        1940,1964,1963,1953,1934,1957,1956,2007,2005,1995,
        2003,2001,1991,1993,1977,1980,1984,1985,2033,2011,
        2028,2013,2025,2018,2017,2004,1955,2010,2006,2058,
        2056,2040,2057,2049,2055,2048,2047,2035,2041,2030,
        2098,2087,2093,2081,2082,2076,2084,2063,2077,2079,
        2078,2123,2039,2134,2132,2073,2126,2127,2119,2112,
        2109,2115,2140,2150,2147,2148,2143,2142,2099,2136,
        2138,2204,2199,2153,2203,2198,2193,2189,2196,2190,
        2159,2275,2278,2269,2270,2266,2267,2252,2255,2256,
        2254,2334,2319,2329,2327,2326,2312,2302,2304,2314,
        2313,2343,2354,2358,2353,2357,2335,2345,2350,2331,
        2340,2390,2385,2389,2377,2322,2382,2383,2380,2371,
        2370,2418,2409,2412,2410,2372,2407,2405,2399,2397,
        2386,2398,2451,2435,2394,2444,2443,2439,2438,2417,
        2430,2428,2431,2495,2485,2491,2487,2466,2467,2469,
        2465,2456,2463,2513,2492,2516,2509,2455,2510,2504,
        2432,2506,2453,2502,2537,2543,2544,2546,2489,2535,
        2471,2534,2533,2503,2572,2564,2528,2566,2560,2554,
        2562,2556,2552,2553,2610,2609,2605,2602,2598,2596,
        2584,2591,2589,2588,2650,2651,2646,2640,2633,2642,
        2643,2637,2636,2570,2676,2675,2679,2671,2647,2669,
        2666,2665,2659,2661,2711,2706,2624,2704,2698,2701,
        2691,2694,2688,2692,2683,2759,2775,2777,2748,2772,
        2771,2767,2763,2757,2740,2734,2814,2811,2791,2808,
        2803,2800,2799,2722,2793,2795,2792,2833,2838,2832,
        2828,2824,2830,2829,2825,2816,2826,2858,2850,2849,
        2848,2840,2835,2844,2842,2846,2845,2827,2876,2880,
        2872,2864,2865,2869,2868,2853,2863,2859,2851,2898,
        2894,2873,2895,2893,2879,2874,2889,2888,2885,2856,
        2917,2903,2904,2906,2908,2852,2901,2886,2900,2930,
        2936,2925,2924,2933,2928,2931,2912,2922,2923,2964,
        2955,2939,2953,2959,2929,2920,2951,2948,2941,2932,
        2973,2979,2978,2966,2974,2968,2950,2970,2961,2958,
        2989,3005,2997,2988,2996,2992,2969,2990,2985,
    ]

    static var allBillerCodes: [String] {
        billerSuffixes.map { billerPrefix + String(format: "%04d", $0) }
    }

    static let randomFirstNames = [
        "James","John","Robert","Michael","David","William","Richard","Joseph","Thomas","Charles",
        "Mary","Patricia","Jennifer","Linda","Barbara","Elizabeth","Susan","Jessica","Sarah","Karen",
        "Daniel","Matthew","Anthony","Mark","Donald","Steven","Paul","Andrew","Joshua","Kenneth",
        "Nancy","Betty","Margaret","Sandra","Ashley","Dorothy","Kimberly","Emily","Donna","Michelle",
    ]

    static let randomLastNames = [
        "Smith","Johnson","Williams","Brown","Jones","Garcia","Miller","Davis","Rodriguez","Martinez",
        "Hernandez","Lopez","Gonzalez","Wilson","Anderson","Thomas","Taylor","Moore","Jackson","Martin",
        "Lee","Perez","Thompson","White","Harris","Sanchez","Clark","Ramirez","Lewis","Robinson",
    ]

    static func generateRandomName() -> String {
        let first = randomFirstNames.randomElement() ?? "John"
        let last = randomLastNames.randomElement() ?? "Smith"
        return "\(first) \(last)"
    }

    static func generateRandom11Digits() -> String {
        var digits = ""
        for _ in 0..<11 {
            digits.append(String(Int.random(in: 0...9)))
        }
        return digits
    }

    static func generateRandomFieldValue() -> String {
        Bool.random() ? generateRandomName() : generateRandom11Digits()
    }
}
