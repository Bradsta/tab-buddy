//
//  SwipeBackEnabler.swift
//  TabBuddy
//
//  The viewer hides the navigation bar to reclaim the top space
//  (`.toolbar(.hidden, for: .navigationBar)`), but hiding the bar also disables
//  UIKit's interactive swipe-from-edge "back" gesture. Restoring the gesture's
//  delegate here re-enables the edge swipe app-wide while keeping the bar hidden.
//

import UIKit

extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    /// Allow the edge-swipe back gesture whenever there's something to pop.
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
