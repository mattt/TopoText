import Foundation

extension Note.FetchRequest {
    /// An error that describes an invalid search request.
    ///
    /// The error descriptions are in English; TopoText does not localize them.
    public enum ValidationError: LocalizedError, Hashable {
        /// The limit is not in the range from 1 through ``Note/FetchRequest/maximumLimit``.
        case limitOutOfRange
        /// The scan limit is not in the range from 1 through ``Note/FetchRequest/maximumScanLimit``.
        case scanLimitOutOfRange
        /// The start date is not earlier than the end date.
        case invalidDateRange

        public var errorDescription: String? {
            switch self {
            case .limitOutOfRange:
                return "The limit must be from 1 through \(Note.FetchRequest.maximumLimit)."
            case .scanLimitOutOfRange:
                return "The scan limit must be from 1 through \(Note.FetchRequest.maximumScanLimit)."
            case .invalidDateRange:
                return "The start date must be earlier than the end date."
            }
        }
    }
}

extension Store.Configuration {
    /// An error that describes an invalid store configuration.
    ///
    /// The error descriptions are in English; TopoText does not localize them.
    public enum ValidationError: LocalizedError, Hashable {
        /// The time limit is not positive.
        case invalidTimeLimit

        public var errorDescription: String? {
            switch self {
            case .invalidTimeLimit:
                return "The time limit must be positive."
            }
        }
    }
}
