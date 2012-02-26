;;; org-notify.el --- Notifications for Org-mode

;; Copyright (C) 2012  Free Software Foundation, Inc.

;; Author: Peter Münster <pmrb@free.fr>
;; Keywords: notification, todo-list, alarm

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Get notifications, when there is something to do.
;; Sometimes, you need a reminder a few days before a deadline, e.g. to buy a
;; present for a birthday, and then another notification one hour before to
;; have enough time to choose the right clothes.
;; For other events, e.g. rolling the dustbin to the roadside once per week,
;; you probably need another kind of notification strategy.
;; This package tries to satisfy the various needs.

;; In order to activate this package, you must add the following code
;; into your .emacs:
;;
;;   (require 'org-notify)
;;   (org-notify-start)

;; Example setup:
;; (org-notify-add 'appt
;;                 '(:time "-1s" :period "20s" :duration 10
;;                   :actions (org-notify-action-message
;;                             org-notify-action-ding))
;;                 '(:time "15m" :period "2m" :duration 100
;;                   :actions org-notify-action-notify)
;;                 '(:time "2h" :period "5m"
;;                   :actions org-notify-action-message)
;;                 '(:time "3d" :actions org-notify-action-email))
;; This means for todo-items with `notify' property set to `appt': 3 days
;; before deadline, send a reminder-email, 2 hours before deadline, start to
;; send messages every 5 minutes, then 15 minutes before deadline, start to
;; pop up notification windows every 2 minutes. The timeout of the window is
;; set to 100 seconds. Finally, when deadline is overdue, send messages and
;; make noise."

;; Take also a look at the function `org-notify-add'.

;;; Code:

(eval-when-compile (require 'cl))
(require 'org-element)

(declare-function appt-delete-window         "appt"           ())
(declare-function appt-select-lowest-window  "appt"           ())
(declare-function notifications-notify       "notifications"  (&rest params))

(defconst orgntf-actions '("done" "done" "hour" "one hour later" "day"
                           "one day later" "week" "one week later")
  "Possible actions for call-back functions.")

(defconst orgntf-window-buffer-name "*org-notify-%s*"
  "Buffer-name for the `org-notify-action-window' function.")

(defvar orgntf-map nil
  "Mapping between names and parameter lists.")

(defvar orgntf-timer nil
  "Timer of the notification daemon.")

(defvar orgntf-parse-file nil
  "Current file, that `org-element-parse-buffer' is parsing.")

(defvar orgntf-on-action-map nil
  "Mapping between on-action identifiers and parameter lists.")

(defvar orgntf-verbose t
  "Print some useful information for developers.")

(defun orgntf-string->seconds (str)
  "Convert time string STR to number of seconds."
  (when str
    (let* ((conv `(("s" . 1) ("m" . 60) ("h" . ,(* 60 60))
                   ("d" . ,(* 24 60 60)) ("w" . ,(* 7 24 60 60))
                   ("M" . ,(* 30 24 60 60))))
           (letters (concat
                     (mapcar (lambda (x) (string-to-char (car x))) conv)))
           (case-fold-search nil))
      (string-match (concat "\\(-?\\)\\([0-9]+\\)\\([" letters "]\\)") str)
      (* (string-to-number (match-string 2 str))
         (cdr (assoc (match-string 3 str) conv))
         (if (= (length (match-string 1 str)) 1) -1 1)))))

(defun orgntf-make-todo (heading &rest ignored)
  "Create one todo item."
  (macrolet ((get (k) `(plist-get list ,k))
             (pr (k v) `(setq result (plist-put result ,k ,v))))
    (let* ((list (nth 1 heading))      (notify (or (get :notify) "default"))
           (deadline (get :deadline))  (heading (get :raw-value))
           result)
      (when (and (eq (get :todo-type) 'todo) heading deadline)
        (pr :heading heading)     (pr :notify (intern notify))
        (pr :begin (get :begin))  (pr :file orgntf-parse-file)
        (pr :timestamp deadline)  (pr :uid (md5 (concat heading deadline)))
        (pr :deadline (- (org-time-string-to-seconds deadline)
                         (org-float-time))))
      result)))

(defun orgntf-todo-list ()
  "Create the todo-list."
  (let ((files (org-agenda-files 'unrestricted)) result)
    (dolist (orgntf-parse-file files result)
      (save-excursion
        (with-current-buffer (find-file-noselect orgntf-parse-file)
          (setq result (append result (org-element-map
                                       (org-element-parse-buffer 'headline)
                                       'headline 'orgntf-make-todo))))))
    result))

(defun orgntf-maybe-too-late (diff period heading)
  "Print waring message, when notified significantly later than defined by
PERIOD."
  (if (> (/ diff period) 1.5)
      (message "Warning: notification for \"%s\" behind schedule!" heading))
  t)

(defun orgntf-process ()
  "Process the todo-list, and possibly notify user about upcoming or
forgotten tasks."
  (macrolet ((prm (k) `(plist-get prms ,k))  (td (k) `(plist-get todo ,k)))
    (dolist (todo (orgntf-todo-list))
      (let* ((deadline (td :deadline))  (heading (td :heading))
             (uid (td :uid))            (last-run-sym
                                         (intern (concat ":last-run-" uid))))
        (dolist (prms (plist-get orgntf-map (td :notify)))
          (when (< deadline (orgntf-string->seconds (prm :time)))
            (let ((period (orgntf-string->seconds (prm :period)))
                  (last-run (prm last-run-sym))  (now (org-float-time))
                  (actions (prm :actions))       diff  plist)
              (when (or (not last-run)
                        (and period (< period (setq diff (- now last-run)))
                             (orgntf-maybe-too-late diff period heading)))
                (setq prms (plist-put prms last-run-sym now)
                      plist (append todo prms))
                (unless (listp actions)
                  (setq actions (list actions)))
                (dolist (action actions)
                  (funcall action plist))))
            (return))))))
)

(defun org-notify-add (name &rest params)
  "Add a new notification type. The NAME can be used in Org-mode property
`notify'. If NAME is `default', the notification type applies for todo items
without the `notify' property. This file predefines such a default
notification type.

Each element of PARAMS is a list with parameters for a given time
distance to the deadline. This distance must increase from one element to
the next.
List of possible parameters:
  :time      Time distance to deadline, when this type of notification shall
             start. It's a string: an integral value (positive or negative)
             followed by a unit (s, m, h, d, w, M).
  :actions   A function or a list of functions to be called to notify the
             user.
  :period    Optional: can be used to repeat the actions periodically. Same
             format as :time.
  :duration  Some actions use this parameter to specify the duration of the
             notification. It's an integral number in seconds.

For the actions, you can use your own functions or some of the predefined
ones, whose names are prefixed with `org-notify-action-'."
  (setq orgntf-map (plist-put orgntf-map name params)))

(defun org-notify-start (&optional secs)
  "Start the notification daemon. If SECS is positive, it's the period in
seconds for processing the notifications, and if negative, notifications
will be checked only when emacs is idle for -SECS seconds. The default value
for SECS is 50."
  (if orgntf-timer
      (org-notify-stop))
  (setq secs (or secs 50)
        orgntf-timer (if (< secs 0)
                         (run-with-idle-timer (* -1 secs) t 'orgntf-process)
                       (run-with-timer secs secs 'orgntf-process))))

(defun org-notify-stop ()
  "Stop the notification daemon."
  (when orgntf-timer
      (cancel-timer orgntf-timer)
      (setq orgntf-timer nil)))

(defun orgntf-on-action (plist key)
  "User wants to see action."
  (save-excursion
    (with-current-buffer (find-file-noselect (plist-get plist :file))
      (show-all)
      (goto-char (plist-get plist :begin))
      (search-forward "DEADLINE: <")
      (cond
       ((string-equal key "done")  (org-todo))
       ((string-equal key "hour")  (org-timestamp-change 60 'minute))
       ((string-equal key "day")   (org-timestamp-up-day))
       ((string-equal key "week")  (org-timestamp-change 7 'day))))))

(defun orgntf-on-action-notify (id key)
  "User wants to see action after mouse-click in notify window."
  (orgntf-on-action (plist-get orgntf-on-action-map id) key)
  (orgntf-on-close id nil))

(defun orgntf-on-action-button (button)
  "User wants to see action after button activation."
  (macrolet ((get (k) `(button-get button ,k)))
    (orgntf-on-action (get 'plist) (get 'key))
    (orgntf-delete-window (get 'buffer))
    (cancel-timer (get 'timer))))

(defun orgntf-delete-window (buffer)
  "Delete the notification window."
  (let ((appt-buffer-name buffer)  (appt-audible nil))
    (appt-delete-window)))

(defun orgntf-on-close (id reason)
  "Notification window has been closed."
  (setq orgntf-on-action-map (plist-put orgntf-on-action-map id nil)))

(defun org-notify-action-message (plist)
  "Print a message."
  (message "TODO: \"%s\" at %s!" (plist-get plist :heading)
           (plist-get plist :timestamp)))

(defun org-notify-action-ding (plist)
  "Make noise."
  (let ((timer (run-with-timer 0 1 'ding)))
    (run-with-timer (or (plist-get plist :duration) 3) nil
                    'cancel-timer timer)))

(defun org-notify-action-email (plist)
  "Send email to user."
; todo
)

(defun org-notify-action-window (plist)
  "Pop up a window, mostly copied from `appt-disp-window'."
  (require 'appt)
  (save-excursion
    (macrolet ((get (k) `(plist-get plist ,k)))
      (let ((this-window (selected-window))
            (buf (get-buffer-create
                  (format orgntf-window-buffer-name (get :uid)))))
        (when (minibufferp)
          (other-window 1)
          (and (minibufferp) (display-multi-frame-p) (other-frame 1)))
        (if (cdr (assq 'unsplittable (frame-parameters)))
            (progn (set-buffer buf) (display-buffer buf))
          (unless (or (special-display-p (buffer-name buf))
                      (same-window-p (buffer-name buf)))
            (appt-select-lowest-window)
            (when (>= (window-height) (* 2 window-min-height))
              (select-window (split-window))))
          (switch-to-buffer buf))
        (setq buffer-read-only nil  buffer-undo-list t)
        (erase-buffer)
        (insert (format "TODO: %s, in %d seconds.\n"
                        (get :heading) (get :deadline)))
        (let ((timer (run-with-timer (or (get :duration) 10) nil
                                     'orgntf-delete-window buf)))
          (dotimes (i (/ (length orgntf-actions) 2))
            (let ((key (nth (* i 2) orgntf-actions))
                  (text (nth (1+ (* i 2)) orgntf-actions)))
              (insert-button text 'action 'orgntf-on-action-button 'key key
                             'buffer buf 'plist plist 'timer timer)
              (insert "    "))))
        (shrink-window-if-larger-than-buffer (get-buffer-window buf t))
        (set-buffer-modified-p nil)       (setq buffer-read-only t)
        (raise-frame (selected-frame))    (select-window this-window)))))

(defun org-notify-action-notify (plist)
  "Pop up a notification window."
; todo: better text for body, take a look at article-lapsed-string
; todo perhaps: dbus-unregister-service for NotificationClosed to
; prevent resetting idle-time
  (require 'notifications)
  (let* ((duration (plist-get plist :duration))
         (id (notifications-notify
              :title     (plist-get plist :heading)
              :body      (format "In %d seconds." (plist-get plist :deadline))
              :timeout   (if duration (* duration 1000))
              :actions   orgntf-actions
              :on-action 'orgntf-on-action-notify
              :on-close  'orgntf-on-close)))
    (setq orgntf-on-action-map (plist-put orgntf-on-action-map id plist))))

(org-notify-add 'default '(:time "1h" :actions org-notify-action-message
                                 :period "2m"))

(provide 'org-notify)

;;; org-notify.el ends here