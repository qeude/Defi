import ApplicationServices
import DefiModel

// Every Accessibility element Defi talks to starts here, so isolated tests trap on the first
// real application or system-wide element instead of reaching the user's apps.
func accessibilityApplication(_ processID: pid_t) -> AXUIElement {
  RealResourceGuard.check("AXUIElementCreateApplication(\(processID))")
  return AXUIElementCreateApplication(processID)
}

func accessibilitySystemWide() -> AXUIElement {
  RealResourceGuard.check("AXUIElementCreateSystemWide")
  return AXUIElementCreateSystemWide()
}
