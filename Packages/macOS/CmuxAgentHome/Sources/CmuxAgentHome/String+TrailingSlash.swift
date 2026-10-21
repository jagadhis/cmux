extension String {
    /// The path without one trailing `/`, except for the root itself.
    var trimmingTrailingSlash: String {
        count > 1 && hasSuffix("/") ? String(dropLast()) : self
    }
}
