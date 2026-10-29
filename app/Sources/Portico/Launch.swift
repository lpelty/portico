/// The process entry: the app, or (with `--update`) the updater window
/// that runs the deployment's update and reopens the app.
@main
enum PorticoLaunch {
    static func main() {
        if Updater.isUpdaterLaunch() {
            UpdaterApp.main()
        } else {
            PorticoApp.main()
        }
    }
}
