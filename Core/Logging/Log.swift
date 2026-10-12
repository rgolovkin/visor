import OSLog

enum Log {
    private static let subsystem = "dev.visor.NotchApp"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let window = Logger(subsystem: subsystem, category: "window")
    static let config = Logger(subsystem: subsystem, category: "config")
    static let widgets = Logger(subsystem: subsystem, category: "widgets")
}
