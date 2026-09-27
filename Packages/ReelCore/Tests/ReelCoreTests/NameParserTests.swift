import XCTest
@testable import ReelCore

// Cases are real names from Bucket_A.
final class NameParserTests: XCTestCase {

    func testRadarrFolder() {
        XCTAssertEqual(NameParser.parseTitle("200 Cigarettes (1999)"), ParsedTitle(title: "200 Cigarettes", year: 1999))
        XCTAssertEqual(NameParser.parseTitle("A Bug's Life (1998)"), ParsedTitle(title: "A Bug's Life", year: 1998))
    }

    func testFolderWithTags() {
        XCTAssertEqual(
            NameParser.parseTitle("Spider-Man Across The Spider-Verse (2023) [1080p] [WEBRip] [x265] [10bit] [5.1] [YTS.MX]"),
            ParsedTitle(title: "Spider-Man Across The Spider-Verse", year: 2023))
        XCTAssertEqual(NameParser.parseTitle("Past Lives (2023) [2160p] [4K] [WEB] [5.1] [YTS.MX]"),
                       ParsedTitle(title: "Past Lives", year: 2023))
    }

    func testEmptyYearAndNoYear() {
        XCTAssertEqual(NameParser.parseTitle("The Old Guard 2 ()"), ParsedTitle(title: "The Old Guard 2", year: nil))
        XCTAssertEqual(NameParser.parseTitle("Toy Story 1"), ParsedTitle(title: "Toy Story 1", year: nil))
    }

    func testReleaseNames() {
        XCTAssertEqual(
            NameParser.parseTitle("Anchorman The Legend of Ron Burgundy 2004 1080p PTV WEB-DL AAC 2 0 H 264-Pi.mkv"),
            ParsedTitle(title: "Anchorman The Legend of Ron Burgundy", year: 2004))
        XCTAssertEqual(
            NameParser.parseTitle("www.UIndex.org    -    200 Cigarettes 1999 1080p BluRay x264-GeneMige.mkv"),
            ParsedTitle(title: "200 Cigarettes", year: 1999))
        XCTAssertEqual(NameParser.parseTitle("Blade.Runner.2049.2017.1080p.BluRay.x264.mkv"),
                       ParsedTitle(title: "Blade Runner 2049", year: 2017))
    }

    func testShowFolders() {
        XCTAssertEqual(NameParser.parseShowFolder("Bluey (2018)"), ParsedTitle(title: "Bluey", year: 2018))
        XCTAssertEqual(NameParser.parseShowFolder("The Office (US)"), ParsedTitle(title: "The Office", year: nil, country: "US"))
        XCTAssertEqual(NameParser.parseShowFolder("Star Wars - Skeleton Crew"), ParsedTitle(title: "Star Wars - Skeleton Crew", year: nil))
        XCTAssertEqual(NameParser.parseShowFolder("Zootopia+"), ParsedTitle(title: "Zootopia+", year: nil))
    }

    func testReleaseEpisode() {
        XCTAssertEqual(
            NameParser.parseEpisode("Bobs.Burgers.S10E13.Three.Girls.and.A.Little.Wharfy.1080p.DSNP.WEB-DL.DDP5.1.H.264-PHOENIX.mkv"),
            ParsedEpisode(season: 10, episode: 13, title: "Three Girls and A Little Wharfy"))
        XCTAssertEqual(
            NameParser.parseEpisode("Ted.Lasso.S04E01.Home.1080p.WEBRip.10Bit.DDP5.1.x265-NeoNoir.mkv"),
            ParsedEpisode(season: 4, episode: 1, title: "Home"))
        XCTAssertEqual(NameParser.parseEpisode("Bluey.S02E31.720p.DSNP.WEBRip.x264-GalaxyTV.mkv"),
                       ParsedEpisode(season: 2, episode: 31, title: nil))
        XCTAssertEqual(NameParser.parseEpisode("Coupling.S03E02.PAL.DVD.AC3.x264-SDB.mkv"),
                       ParsedEpisode(season: 3, episode: 2, title: nil))
        XCTAssertEqual(
            NameParser.parseEpisode("Daddy.Issues.2024.S02E03.Its.a.Plum.1080p.WEBRip.x264-CBFM[EZTVx.to].mkv"),
            ParsedEpisode(season: 2, episode: 3, title: "Its a Plum"))
    }

    func testSpacedEpisode() {
        XCTAssertEqual(
            NameParser.parseEpisode("How I Met Your Mother S03E17 The Goat (1080p x265 Joy).m4v"),
            ParsedEpisode(season: 3, episode: 17, title: "The Goat"))
        XCTAssertEqual(
            NameParser.parseEpisode("The Gentlemen S02E03 Do You Reject Satan REPACK 1080p NF WEB-DL DDP5 1 Atmos H 264-playWEB.mkv"),
            ParsedEpisode(season: 2, episode: 3, title: "Do You Reject Satan"))
        XCTAssertEqual(NameParser.parseEpisode("The Middle S04E24 The Graduation.mp4"),
                       ParsedEpisode(season: 4, episode: 24, title: "The Graduation"))
    }

    func testMultiEpisode() {
        XCTAssertEqual(NameParser.parseEpisode("The.Office.US.S04E07E08.1080p.BluRay.x265-RARBG.mp4"),
                       ParsedEpisode(season: 4, episode: 7, episodeEnd: 8, title: nil))
    }

    func testPinchflat() {
        XCTAssertEqual(
            NameParser.parseEpisode("Little Bear - s01e38 - Little Bear ｜ Emily’s Birthday ⧸ The Great Race ⧸ Circus For Tutu - Ep. 38.webm")?.title,
            "Little Bear ｜ Emily’s Birthday ⧸ The Great Race ⧸ Circus For Tutu - Ep. 38")
        let ms = NameParser.parseEpisode("s2026e0506 - Animal Learning for Toddlers with Ms Rachel - 3 Full Episodes - Learn Animal Sounds - Best Videos.mp4")
        XCTAssertEqual(ms?.season, 2026)
        XCTAssertEqual(ms?.episode, 506)
        XCTAssertEqual(ms?.title, "Animal Learning for Toddlers with Ms Rachel - 3 Full Episodes - Learn Animal Sounds - Best Videos")
    }

    func testSitePrefixEpisode() {
        XCTAssertEqual(
            NameParser.parseEpisode("www.Torrenting.com - Star Wars Skeleton Crew S01E02 1080p WEBRip HDR10 10Bit DDP5 1 Atmos H265-d3g.mkv"),
            ParsedEpisode(season: 1, episode: 2, title: nil))
    }

    func testNoEpisodeNumber() {
        XCTAssertNil(NameParser.parseEpisode("aaf-pingu.special.pingu.at.the.wedding.party.dvdrip.xvid.avi"))
        XCTAssertEqual(NameParser.looseEpisodeTitle("aaf-pingu.special.pingu.at.the.wedding.party.dvdrip.xvid.avi"),
                       "aaf-pingu special pingu at the wedding party")
    }

    func testSeasonFolders() {
        XCTAssertEqual(NameParser.seasonNumber(folder: "Season 7"), 7)
        XCTAssertEqual(NameParser.seasonNumber(folder: "Season 01"), 1)
        XCTAssertEqual(NameParser.seasonNumber(folder: "Specials"), 0)
        XCTAssertEqual(NameParser.seasonNumber(folder: "The Middle S04 (360p re-webrip)"), nil)
        XCTAssertEqual(NameParser.seasonNumber(folder: "Season NA"), nil)
    }

    func testSubtitles() {
        let stem = "Sweethearts (2024) [1080p] [WEBRip] [5.1] [YTS.MX]"
        XCTAssertEqual(NameParser.parseSubtitle(fileName: "\(stem).da.hi.srt", videoStem: stem).label, "Danish (SDH)")
        XCTAssertEqual(NameParser.parseSubtitle(fileName: "\(stem).en.forced.srt", videoStem: stem).label, "English (Forced)")
        XCTAssertEqual(NameParser.parseSubtitle(fileName: "\(stem).da.srt", videoStem: stem).languageCode, "da")
        XCTAssertEqual(NameParser.parseSubtitle(fileName: "2_English.srt", videoStem: stem).label, "English")
    }
}
