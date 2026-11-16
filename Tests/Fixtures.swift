import Foundation

/// Server answers recorded from Emby 4.8 and Jellyfin 10.9 and trimmed to the fields Cove reads (ids, tags and
/// names replaced). Emby sends most fields even when empty; Jellyfin leaves out what it doesn't have and adds
/// ImageBlurHashes. Kept as string literals so the test target needs no resources.
enum Fixtures {
    static let embySystemInfoPublic = """
    {"LocalAddress":"http://192.168.1.10:8096","ServerName":"Living Room","Version":"4.8.10.0",
     "ProductName":"Emby Server","Id":"5c0e7bd3a8f84e7c9b7b0f2a1d6e9c41"}
    """

    static let jellyfinSystemInfoPublic = """
    {"LocalAddress":"http://192.168.1.11:8096","ServerName":"jelly","Version":"10.9.11",
     "ProductName":"Jellyfin Server","OperatingSystem":"","Id":"a1b2c3d4e5f60718293a4b5c6d7e8f90","StartupWizardCompleted":true}
    """

    /// GET /Users/{id}/Items (a movie library page, Emby).
    static let embyLibraryPage = """
    {"Items":[
      {"Name":"The Matrix","ServerId":"5c0e7bd3","Id":"1001","RunTimeTicks":81720000000,"ProductionYear":1999,
       "CommunityRating":8.2,"IsFolder":false,"Type":"Movie","Overview":"A hacker learns the truth.",
       "Genres":["Action","Science Fiction"],"ProviderIds":{"Imdb":"tt0133093","Tmdb":"603"},
       "UserData":{"PlaybackPositionTicks":12340000000,"PlayCount":0,"IsFavorite":true,"Played":false},
       "PrimaryImageAspectRatio":0.6666666666666666,"ImageTags":{"Primary":"f00dcafe","Logo":"10601060"},
       "BackdropImageTags":["bacd0001"],"MediaType":"Video"},
      {"Name":"Arrival","ServerId":"5c0e7bd3","Id":"1002","RunTimeTicks":69480000000,"ProductionYear":2016,
       "CommunityRating":7.6,"IsFolder":false,"Type":"Movie","Genres":["Drama"],"ProviderIds":{"Imdb":"tt2543164"},
       "UserData":{"PlaybackPositionTicks":0,"PlayCount":2,"IsFavorite":false,"Played":true,"LastPlayedDate":"2026-10-01T20:11:02.0000000Z"},
       "ImageTags":{"Primary":"beef0002"},"BackdropImageTags":[],"MediaType":"Video"},
      {"Name":"Severance","ServerId":"5c0e7bd3","Id":"2001","ProductionYear":2022,"CommunityRating":8.7,
       "IsFolder":true,"Type":"Series","Status":"Continuing","EndDate":null,
       "UserData":{"UnplayedItemCount":7,"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":false},
       "ImageTags":{"Primary":"5e7e0001"},"BackdropImageTags":["5e7eb001"]}
     ],"TotalRecordCount":143}
    """

    /// GET /Shows/{id}/Episodes (Jellyfin): optional fields left out, blur hashes, series image on the episode.
    static let jellyfinEpisodes = """
    {"Items":[
      {"Name":"Good News About Hell","ServerId":"a1b2c3d4","Id":"e7f1a2b3c4d5e6f708192a3b4c5d6e7f","HasSubtitles":true,
       "Container":"mkv","PremiereDate":"2022-02-18T00:00:00.0000000Z","RunTimeTicks":34530000000,"ProductionYear":2022,
       "IndexNumber":1,"ParentIndexNumber":1,"IsFolder":false,"Type":"Episode",
       "ParentBackdropItemId":"5e7e5e7e5e7e5e7e5e7e5e7e5e7e5e7e","ParentBackdropImageTags":["pbt0000001"],
       "UserData":{"PlaybackPositionTicks":0,"PlayCount":1,"IsFavorite":false,"Played":true,"Key":"371980001"},
       "SeriesName":"Severance","SeriesId":"5e7e5e7e5e7e5e7e5e7e5e7e5e7e5e7e","SeasonId":"5ea50001","SeriesPrimaryImageTag":"spt0000001",
       "ImageTags":{"Primary":"ept0000001"},"BackdropImageTags":[],
       "ImageBlurHashes":{"Primary":{"ept0000001":"WDB:,m00~qxuM{t7","spt0000001":"dGF5OmVk00of~qay"},
                          "Backdrop":{"pbt0000001":"WQF~1yIU%MRjRjxu"}},
       "LocationType":"FileSystem","MediaType":"Video"},
      {"Name":"Half Loop","ServerId":"a1b2c3d4","Id":"e7f1a2b3c4d5e6f708192a3b4c5d6e80","RunTimeTicks":32760000000,
       "IndexNumber":2,"ParentIndexNumber":1,"IsFolder":false,"Type":"Episode",
       "UserData":{"PlaybackPositionTicks":9000000000,"PlayCount":0,"IsFavorite":false,"Played":false,"Key":"371980002"},
       "SeriesName":"Severance","SeriesId":"5e7e5e7e5e7e5e7e5e7e5e7e5e7e5e7e","SeasonId":"5ea50001",
       "ImageTags":{},"BackdropImageTags":[],"MediaType":"Video"}
     ],"TotalRecordCount":2,"StartIndex":0}
    """

    /// GET /Users/{id}/Items/Latest: a bare array; Jellyfin ignores IncludeItemTypes and mixes in music.
    static let jellyfinLatest = """
    [{"Name":"Dune: Part Two","Id":"m1","Type":"Movie","ProductionYear":2024},
     {"Name":"Random Access Memories","Id":"a1","Type":"MusicAlbum","ProductionYear":2013},
     {"Name":"Shogun","Id":"s1","Type":"Series","ProductionYear":2024}]
    """

    /// GET /Users/{id}/Items/{id} with MediaSources (Emby).
    static let embyFullMovie = """
    {"Name":"The Matrix","Id":"1001","Type":"Movie","RunTimeTicks":81720000000,"CommunityRating":8.2,"CriticRating":83,
     "OfficialRating":"R","Genres":["Action","Science Fiction"],"Taglines":["Welcome to the Real World."],
     "Studios":[{"Name":"Warner Bros. Pictures","Id":77}],
     "People":[{"Name":"Keanu Reeves","Id":"p1","Role":"Neo","Type":"Actor","PrimaryImageTag":"pp1"},
               {"Name":"Lana Wachowski","Id":"p2","Type":"Director"}],
     "ProviderIds":{"Imdb":"tt0133093","Tmdb":"603"},"ExternalUrls":[{"Name":"IMDb","Url":"https://www.imdb.com/title/tt0133093"}],
     "RemoteTrailers":[{"Url":"https://www.youtube.com/watch?v=vKQi3bBA1y8"}],
     "UserData":{"PlaybackPositionTicks":0,"Played":false,"IsFavorite":true,"LastPlayedDate":"2026-09-30T19:00:00.0000000Z"},
     "Chapters":[{"StartPositionTicks":0,"Name":"Chapter 1"},
                 {"StartPositionTicks":3000000000,"Name":"Intro","MarkerType":"IntroEnd"}],
     "MediaSources":[{"Protocol":"File","Id":"src1","Path":"/media/movies/The Matrix (1999).mkv","Type":"Default",
       "Container":"mkv","Size":28547219456,"Name":"The Matrix 2160p","IsRemote":false,"SupportsDirectPlay":false,
       "MediaStreams":[
         {"Codec":"hevc","VideoRange":"HDR 10","DisplayTitle":"4K HEVC HDR","IsDefault":true,"Type":"Video","Index":0,"Width":3840,"Height":1600,"BitRate":60000000},
         {"Codec":"truehd","Language":"eng","DisplayTitle":"English TRUEHD 7.1 (Default)","IsDefault":true,"Type":"Audio","Index":1},
         {"Codec":"pgssub","Language":"ron","DisplayTitle":"Romanian (PGSSUB)","IsDefault":false,"Type":"Subtitle","Index":2},
         {"Codec":"subrip","Language":"ron","DisplayTitle":"Romanian (SRT)","IsDefault":false,"Type":"Subtitle","Index":3}]}]}
    """

    /// POST /Items/{id}/PlaybackInfo (Emby): an mp4 the Mac can direct play.
    static let embyPlaybackInfoDirect = """
    {"MediaSources":[{"Protocol":"File","Id":"src1","Container":"mp4","SupportsDirectPlay":true,"SupportsDirectStream":true,
      "SupportsTranscoding":true,"MediaStreams":[]}],"PlaySessionId":"0f1e2d3c4b5a69788796a5b4c3d2e1f0"}
    """

    /// POST /Items/{id}/PlaybackInfo (Jellyfin): mkv, transcode URL relative to the server.
    static let jellyfinPlaybackInfoTranscode = """
    {"MediaSources":[{"Protocol":"File","Id":"src9","Container":"mkv","SupportsDirectPlay":false,"SupportsDirectStream":false,
      "SupportsTranscoding":true,
      "TranscodingUrl":"/videos/e7f1/master.m3u8?DeviceId=dev&MediaSourceId=src9&VideoCodec=h264&AudioCodec=aac&PlaySessionId=abc123&SubtitleStreamIndex=5&SubtitleMethod=Encode&VideoBitrate=139616000&TranscodingMaxAudioChannels=2&SegmentContainer=ts",
      "TranscodingSubProtocol":"hls","TranscodingContainer":"ts","MediaStreams":[]}],"PlaySessionId":"abc123"}
    """

    /// The same, but the transcode URL names an absolute address (`host`, e.g. a reverse proxy's).
    static func playbackInfoTranscode(at host: String) -> String {
        """
        {"MediaSources":[{"Id":"src9","Container":"mkv","SupportsDirectPlay":false,
          "TranscodingUrl":"\(host)/videos/e7f1/master.m3u8?MediaSourceId=src9&PlaySessionId=abc123"}],"PlaySessionId":"abc123"}
        """
    }

    static let malformed = #"{"Items":[{"Id":"1","Name":"#
}
