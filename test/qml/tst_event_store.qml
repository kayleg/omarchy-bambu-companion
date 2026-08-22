import QtQuick
import QtTest
import "../.."

TestCase {
  name: "BambuEventStoreBehavior"

  BambuEventStore { id: store }

  function init() {
    store.events = []
    store.activeAlerts = ({})
    store.nextEventId = 1
    store.demoEventsLoaded = false
    store.recount()
  }

  function context() {
    return {
      printerName: "Workshop",
      productName: "Bambu Lab P1S",
      firmwareVersion: "1.2.3",
      jobName: "benchy.gcode.3mf",
      printerState: "RUNNING"
    }
  }

  function test_print_timeline_and_unread_policy() {
    store.recordPrintTransition("IDLE", "RUNNING", "", "benchy.gcode.3mf",
                                context(), "2026-08-21T12:00:00Z")
    compare(store.events.length, 1)
    compare(store.events[0].title, "Print started")
    verify(store.events[0].read)

    store.recordPrintTransition("RUNNING", "PAUSE", "benchy.gcode.3mf",
                                "benchy.gcode.3mf", context(),
                                "2026-08-21T12:01:00Z")
    compare(store.unreadWarningCount, 1)
    compare(store.unreadErrorCount, 0)
  }

  function test_alert_classification_read_and_clear() {
    store.reconcileAlerts([{ id: "maintenance", kind: "warning",
      title: "Maintenance", description: "Lubricate", code: "HMS_TEST" }],
      context(), "2026-08-21T12:00:00Z")
    compare(store.activeErrorCount, 0)
    compare(store.unreadWarningCount, 1)
    verify(store.events[0].active)

    var maintenanceId = store.events[0].id
    store.reconcileAlerts([{ id: "maintenance", kind: "warning",
      title: "Maintenance", description: "Lubricate", code: "HMS_TEST" }],
      context(), "2026-08-21T12:00:30Z")
    compare(store.events.length, 1)
    compare(store.events[0].id, maintenanceId)

    store.reconcileAlerts([{ id: "fault", kind: "error",
      title: "Print error", description: "Stopped", code: "0x12345678" }],
      context(), "2026-08-21T12:01:00Z")
    compare(store.activeErrorCount, 1)
    compare(store.unreadErrorCount, 1)
    verify(store.events[1].clearedAt !== "")

    verify(store.markRead(store.events[0].id))
    compare(store.unreadErrorCount, 0)
    verify(store.markAllRead())
    compare(store.unreadCount, 0)

    store.reconcileAlerts([], context(), "2026-08-21T12:02:00Z")
    compare(store.activeErrorCount, 0)
    verify(store.events[0].clearedAt !== "")
  }

  function test_demo_fixture_is_labelled_bounded_idempotent_and_removable() {
    verify(store.loadDemoEvents())
    compare(store.events.length, 28)
    compare(store.unreadErrorCount, 2)
    compare(store.unreadWarningCount, 2)
    compare(store.activeErrorCount, 0)
    compare(store.events[0].source, "demo")
    compare(store.events[0].title, "Printer error")
    verify(store.events[0].description.indexOf("No real printer") >= 0)
    verify(store.events[2].active)
    compare(store.events[2].severity, "warning")
    verify(store.events[27].read)
    verify(store.events[27].timestamp < store.events[0].timestamp)
    verify(!store.loadDemoEvents())
    compare(store.events.length, 28)
    verify(store.clearDemoEvents())
    compare(store.events.length, 0)
    compare(store.unreadCount, 0)
    compare(store.activeErrorCount, 0)
  }
}
