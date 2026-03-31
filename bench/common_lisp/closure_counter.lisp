(defun make-counter (n)
	(lambda ()
		(setf n (+ n 1))
		n))

(defun drive (counter remaining last)
	(if (= remaining 0)
		last
		(drive counter (- remaining 1) (funcall counter))))

(let ((c (make-counter 0)))
	(write (drive c 1000 0))
	(terpri))
;; SPDX-License-Identifier: MPL-2.0
;;
