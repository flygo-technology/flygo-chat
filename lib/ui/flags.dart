import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Quốc kỳ của mỗi ngôn ngữ trong app (vẽ bằng SVG: Windows không hiện được emoji cờ).
const _flags = {
  'vi': '<svg viewBox="0 0 30 20"><rect width="30" height="20" fill="#DA251D"/>'
      '<polygon fill="#FFFF00" points="15.00,4.00 16.35,8.15 20.71,8.15 17.18,10.71 18.53,14.85 15.00,12.29 11.47,14.85 12.82,10.71 9.29,8.15 13.65,8.15"/></svg>',
  'en': '<svg viewBox="0 0 60 30"><clipPath id="t"><path d="M30,15 h30 v15 z v15 h-30 z h-30 v-15 z v-15 h30 z"/></clipPath>'
      '<rect width="60" height="30" fill="#012169"/>'
      '<path d="M0,0 L60,30 M60,0 L0,30" stroke="#FFFFFF" stroke-width="6"/>'
      '<path d="M0,0 L60,30 M60,0 L0,30" clip-path="url(#t)" stroke="#C8102E" stroke-width="4"/>'
      '<path d="M30,0 v30 M0,15 h60" stroke="#FFFFFF" stroke-width="10"/>'
      '<path d="M30,0 v30 M0,15 h60" stroke="#C8102E" stroke-width="6"/></svg>',
  'ko': '<svg viewBox="0 0 30 20"><rect width="30" height="20" fill="#FFFFFF"/>'
      '<g transform="rotate(33.7 15 10)"><circle cx="15" cy="10" r="5" fill="#0047A0"/>'
      '<path d="M10,10 A5,5 0 0 1 20,10 A2.5,2.5 0 0 1 15,10 A2.5,2.5 0 0 0 10,10 Z" fill="#CD2E3A"/></g>'
      '<g fill="#000000">'
      '<g transform="rotate(-56.3 6.5 4.5)"><rect x="4.5" y="3.4" width="4" height="0.6"/><rect x="4.5" y="4.3" width="4" height="0.6"/><rect x="4.5" y="5.2" width="4" height="0.6"/></g>'
      '<g transform="rotate(56.3 23.5 4.5)"><rect x="21.5" y="3.4" width="4" height="0.6"/><rect x="21.5" y="4.3" width="4" height="0.6"/><rect x="21.5" y="5.2" width="4" height="0.6"/></g>'
      '<g transform="rotate(56.3 6.5 15.5)"><rect x="4.5" y="14.4" width="4" height="0.6"/><rect x="4.5" y="15.3" width="4" height="0.6"/><rect x="4.5" y="16.2" width="4" height="0.6"/></g>'
      '<g transform="rotate(-56.3 23.5 15.5)"><rect x="21.5" y="14.4" width="4" height="0.6"/><rect x="21.5" y="15.3" width="4" height="0.6"/><rect x="21.5" y="16.2" width="4" height="0.6"/></g>'
      '</g></svg>',
  'ja': '<svg viewBox="0 0 30 20"><rect width="30" height="20" fill="#FFFFFF"/><circle cx="15" cy="10" r="6" fill="#BC002D"/></svg>',
  'th': '<svg viewBox="0 0 30 20"><rect width="30" height="20" fill="#A51931"/><rect y="3.33" width="30" height="13.34" fill="#F4F5F8"/>'
      '<rect y="6.67" width="30" height="6.66" fill="#2D2A4A"/></svg>',
  'zh': '<svg viewBox="0 0 30 20"><rect width="30" height="20" fill="#EE1C25"/><g fill="#FFFF00">'
      '<polygon points="5.00,2.00 5.67,4.07 7.85,4.07 6.09,5.35 6.76,7.43 5.00,6.15 3.24,7.43 3.91,5.35 2.15,4.07 4.33,4.07"/>'
      '<polygon points="10.00,1.00 10.22,1.69 10.95,1.69 10.36,2.12 10.59,2.81 10.00,2.38 9.41,2.81 9.64,2.12 9.05,1.69 9.78,1.69"/>'
      '<polygon points="12.00,3.00 12.22,3.69 12.95,3.69 12.36,4.12 12.59,4.81 12.00,4.38 11.41,4.81 11.64,4.12 11.05,3.69 11.78,3.69"/>'
      '<polygon points="12.00,6.00 12.22,6.69 12.95,6.69 12.36,7.12 12.59,7.81 12.00,7.38 11.41,7.81 11.64,7.12 11.05,6.69 11.78,6.69"/>'
      '<polygon points="10.00,8.00 10.22,8.69 10.95,8.69 10.36,9.12 10.59,9.81 10.00,9.38 9.41,9.81 9.64,9.12 9.05,8.69 9.78,8.69"/>'
      '</g></svg>',
};

/// Cờ nhỏ bo góc của ngôn ngữ [lang] (mã trong appLanguages); ngôn ngữ chưa có cờ thì trống.
class LangFlag extends StatelessWidget {
  final String lang;
  final double width;
  const LangFlag(this.lang, {super.key, this.width = 28});

  @override
  Widget build(BuildContext context) {
    final svg = _flags[lang];
    final h = width * 2 / 3;
    if (svg == null) return SizedBox(width: width, height: h);
    return Container(
      width: width,
      height: h,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: Colors.black.withValues(alpha: .15), width: .5),
      ),
      clipBehavior: Clip.antiAlias,
      child: SvgPicture.string(svg, fit: BoxFit.cover),
    );
  }
}
