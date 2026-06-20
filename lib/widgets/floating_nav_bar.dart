import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// Bottom navigation bar with a raised circular FAB-style button
/// for the Scan tab in the center, flanked by News and Records.
class FloatingNavBar extends StatelessWidget {
  final int currentIndex; // 0 = News, 1 = Scan, 2 = Records
  final ValueChanged<int> onTap;
  final bool dark; // true when the Scan/camera screen is active

  const FloatingNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.dark = false,
  });

  @override
  Widget build(BuildContext context) {
    final Color barBg = dark ? AppColors.cameraBg : AppColors.surface;
    final Color borderColor =
    dark ? const Color(0xFF1E1E1E) : AppColors.border;
    final Color inactiveColor =
    dark ? Colors.white.withValues(alpha: 0.3) : AppColors.muted;

    return Container(
      height: 64,
      decoration: BoxDecoration(
        color: barBg,
        border: Border(top: BorderSide(color: borderColor, width: 0.6)),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Row(
            children: [
              _NavItem(
                icon: Icons.newspaper_outlined,
                activeIcon: Icons.newspaper,
                label: 'News',
                isActive: currentIndex == 0,
                inactiveColor: inactiveColor,
                onTap: () => onTap(0),
              ),
              // Reserve center space for the floating button
              const SizedBox(width: 76),
              _NavItem(
                icon: Icons.list_alt_outlined,
                activeIcon: Icons.list_alt,
                label: 'Records',
                isActive: currentIndex == 2,
                inactiveColor: inactiveColor,
                onTap: () => onTap(2),
              ),
            ],
          ),

          // Floating center Scan button
          Positioned(
            top: -22,
            left: 0,
            right: 0,
            child: Center(
              child: GestureDetector(
                onTap: () => onTap(1),
                child: Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: barBg, // ring matching the bar behind it
                  ),
                  child: Center(
                    child: Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.accentLight,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.accentLight.withValues(alpha: 0.4),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.camera_alt,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 6,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                'Scan',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: currentIndex == 1 ? FontWeight.w600 : FontWeight.w400,
                  color: currentIndex == 1 ? AppColors.accentLight : inactiveColor,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isActive;
  final Color inactiveColor;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.isActive,
    required this.inactiveColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final Color color = isActive ? AppColors.accentLight : inactiveColor;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(isActive ? activeIcon : icon, color: color, size: 20),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}