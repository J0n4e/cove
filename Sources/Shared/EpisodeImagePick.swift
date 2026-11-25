import Foundation

/// Which picture an episode card shows. Episode cards are always a 16:9 frame; when the episode's own Primary
/// image is a portrait poster (some libraries set the show poster as the episode picture), a wide image is
/// used instead, in this order: the episode's Thumb, the episode's backdrop, the season's Thumb, the show's
/// Thumb, the show's backdrop. Only when none exists is the poster used (cropped into the frame).
/// A missing aspect ratio counts as wide, as before.
enum EpisodeImagePick {
    struct Input: Equatable {
        var id: String
        var primaryAspect: Double? = nil
        var imageTags: [String: String] = [:]
        var backdropTags: [String] = []
        var seriesId: String? = nil
        var parentThumbId: String? = nil
        var parentThumbTag: String? = nil
        var seriesThumbTag: String? = nil
        var parentBackdropId: String? = nil
        var parentBackdropTags: [String] = []
    }

    static func isPortrait(_ aspect: Double?) -> Bool {
        guard let a = aspect, a > 0 else { return false }
        return a < 1
    }

    static func pick(_ i: Input) -> (itemId: String, imageType: String) {
        guard isPortrait(i.primaryAspect) else { return (i.id, "Primary") }
        if i.imageTags["Thumb"] != nil { return (i.id, "Thumb") }
        if !i.backdropTags.isEmpty { return (i.id, "Backdrop") }
        // The server points ParentThumb at the nearest owner with a Thumb: the season, or else the show
        if let p = i.parentThumbId, i.parentThumbTag != nil, p != i.seriesId { return (p, "Thumb") }
        if let s = i.seriesId, i.seriesThumbTag != nil { return (s, "Thumb") }
        if let p = i.parentThumbId, i.parentThumbTag != nil { return (p, "Thumb") }
        if let p = i.parentBackdropId, !i.parentBackdropTags.isEmpty { return (p, "Backdrop") }
        return (i.id, "Primary")
    }

    static func input(_ it: Item) -> Input {
        Input(id: it.Id, primaryAspect: it.PrimaryImageAspectRatio, imageTags: it.ImageTags ?? [:],
              backdropTags: it.BackdropImageTags ?? [], seriesId: it.SeriesId,
              parentThumbId: it.ParentThumbItemId, parentThumbTag: it.ParentThumbImageTag,
              seriesThumbTag: it.SeriesThumbImageTag, parentBackdropId: it.ParentBackdropItemId,
              parentBackdropTags: it.ParentBackdropImageTags ?? [])
    }

    static func pick(_ it: Item) -> (itemId: String, imageType: String) { pick(input(it)) }
}
