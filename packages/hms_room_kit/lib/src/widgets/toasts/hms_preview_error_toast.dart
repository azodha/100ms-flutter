///Package imports
library;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

///Project imports
import 'package:hms_room_kit/src/widgets/common_widgets/hms_subheading_text.dart';

///[HMSPreviewErrorToast] renders the toast shown on the preview screen when
///the user fails to join the meeting. It shows a title, a short description
///and a "Try again" action to retry joining.
class HMSPreviewErrorToast extends StatelessWidget {
  final String title;
  final String description;
  final Function onRetryPressed;
  const HMSPreviewErrorToast({
    super.key,
    required this.onRetryPressed,
    this.title = "Couldn't join the meeting",
    this.description = "Something went wrong.",
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1D2939),
      padding: const EdgeInsets.only(left: 16, right: 12, top: 12, bottom: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 28,
                  height: 28,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: 26,
                        height: 26,
                        decoration: const BoxDecoration(
                          color: Color(0x40F97066),
                          shape: BoxShape.circle,
                        ),
                      ),
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A2E26),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0x40FDA29B),
                          ),
                        ),
                      ),
                      SvgPicture.asset(
                        "packages/hms_room_kit/lib/src/assets/icons/alert_circle.svg",
                        width: 14,
                        height: 14,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      HMSSubheadingText(
                        text: title,
                        textColor: const Color(0xFFFCFCFD),
                        fontSize: 14,
                        lineHeight: 20,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0,
                      ),
                      HMSSubheadingText(
                        text: description,
                        textColor: const Color(0xFFD5D9EB),
                        fontSize: 12,
                        lineHeight: 16,
                        fontWeight: FontWeight.w400,
                        letterSpacing: 0,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: () => onRetryPressed(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF6769DB),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                "Try again",
                style: TextStyle(
                  fontSize: 14,
                  height: 20 / 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
