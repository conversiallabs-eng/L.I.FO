import 'package:flutter/material.dart';

class AppColors {
  // Ultra-professional Circuit-grade stealth palette for vehicle cabin GPS operations.
  // Zero pastel tones. High-contrast deep carbon, sharp slate, and electric navigation accents.

  // Circuit Core Accents
  static const Color circuitBlue = Color(0xFF0066FF);
  static const Color circuitBlueGlow = Color(0xFF2979FF);
  static const Color circuitCyan = Color(0xFF00E5FF);
  static const Color circuitGreen = Color(0xFF00E676);
  static const Color circuitAmber = Color(0xFFFFB300);
  static const Color circuitRed = Color(0xFFFF3D00);

  // Stealth Carbon Dark (Circuit Theme)
  static const Color carbonBackground = Color(0xFF090C11);
  static const Color carbonSurface = Color(0xFF131822);
  static const Color carbonSurfaceElevated = Color(0xFF1B2230);
  static const Color carbonSurfaceInput = Color(0xFF232C3D);
  static const Color carbonBorder = Color(0xFF2A3549);
  static const Color carbonBorderSubtle = Color(0xFF1F2737);

  // Typography High Contrast
  static const Color textWhite = Color(0xFFFFFFFF);
  static const Color textSlate = Color(0xFF94A3B8);
  static const Color textMuted = Color(0xFF64748B);

  // Aliases for unified dark-carbon vehicle cabin components
  static const Color darkBackground = carbonBackground;
  static const Color darkSurface = carbonSurface;
  static const Color darkSurfaceElevated = carbonSurfaceElevated;
  static const Color darkBorder = carbonBorder;
  static const Color darkTextPrimary = textWhite;
  static const Color darkTextSecondary = textSlate;
  static const Color darkTextMuted = textMuted;

  // Daylight / High-contrast alternate — segue o tema do dispositivo.
  // Claro de verdade para sol forte na cabine; escuro continua carbon stealth.
  static const Color lightBackground = Color(0xFFF1F5F9);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceElevated = Color(0xFFE8EEF5);
  static const Color lightSurfaceInput = Color(0xFFF1F5F9);
  static const Color lightBorder = Color(0xFFCBD5E1);
  static const Color lightBorderSubtle = Color(0xFFE2E8F0);
  static const Color lightTextPrimary = Color(0xFF0F172A);
  static const Color lightTextSecondary = Color(0xFF475569);
  static const Color lightTextMuted = Color(0xFF94A3B8);

  // Status Colors (Ultra high contrast)
  static const Color statusSuccess = circuitGreen;
  static const Color statusWarning = circuitAmber;
  static const Color statusDanger = circuitRed;
  static const Color statusNeutral = Color(0xFF475569);
  static const Color primaryBlue = circuitBlue;
  static const Color primaryBlueLight = circuitBlueGlow;
  static const Color accentCyan = circuitCyan;
  static const Color accentAmber = circuitAmber;

  // Spatial Slots - High Contrast Professional Badges
  static const Color slotRearDoor = Color(0xFF00E676);
  static const Color slotSideDoor = Color(0xFF00E5FF);
  static const Color slotMidRight = Color(0xFF2979FF);
  static const Color slotMidLeft = Color(0xFF7C4DFF);
  static const Color slotDeepRight = Color(0xFFFF9100);
  static const Color slotDeepLeft = Color(0xFFFF1744);

  // Route Polyline & Vector Pins
  static const Color routePolyline = Color(0xFF2979FF);
  static const Color routePolylineDay = Color(0xFF2979FF);
  static const Color routePolylineNight = Color(0xFF2979FF);
  static const Color routePolylineGlow = Color(0xFF0052CC);
  static const Color routeCompleted = Color(0xFF334155);
  static const Color markerCurrent = Color(0xFF0066FF);
  static const Color markerCompleted = Color(0xFF334155);
  static const Color markerNext = Color(0xFF00E676);
}
