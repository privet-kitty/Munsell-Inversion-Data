(defpackage :mid
  (:use :common-lisp :dufy :dufy-munsell :lparallel :alexandria)
  (:export :make-munsell-inversion-data
	   :interpolate-mid
	   :load-munsell-inversion-data
	   :save-munsell-inversion-data
	   :qrgb-to-mhvc
	   :qrgb-to-munsell
	   :rgbpack-to-mhvc
	   :build-mid
	   :examine-interpolation-error
	   :examine-luminance-error
	   :check-error-of-hex
	   :encode-mhvc1000
	   :decode-mhvc1000
	   :decode-mhvc
	   :interpolatedp
	   :set-interpolated
	   :delete-interpolated-nodes
	   :fill-mid-with-inverter
	   :count-gaps
	   :count-interpolated
	   :count-bad-nodes))

(in-package :mid)

(setf *kernel* (make-kernel 3))

;;
;; Here we generate inversion data from 24-bit RGB to Munsell.
;;

(defconstant possible-colors 16777216) ;256*256*256

;; Munsell inversion data (hereinafter called MID) is a 
;; 16777216 * 32 bit binary data in big endian format: 
;;  0  0  0000000000  0000000000  0000000000
;; [A][ ][    B     ][    C     ][    D     ]
;; A: flag of large interpolation error:
;; let f the function from Munsell to RGB in the library dufy;
;; if and only if the flag of a node MID[hex] is 1, then
;; delta-Eab(hex, f(MID[hex])) >= 1.0.
;; B: quantized hue by 0.1; {0R (= 10RP), 0.1R, 0.2R, ..., 10RP} -> Z/{0, 1, ..., 1000};
;; C: quantized value by 0.01; [0, 10] -> {0, 1, ..., 1000};
;; D: quantized chroma by 0.1; [0, 50] -> {0, 1, ..., 500};

(defun encode-mhvc1000 (h1000 v1000 c500 &optional (flag-interpolated 0))
  (declare (optimize (speed 3) (safety 1))
	   ((integer 0 1000) h1000 v1000 c500)
	   ((integer 0 1) flag-interpolated))
  (+ (ash flag-interpolated 31)
     (ash h1000 20)
     (ash v1000 10)
     c500))

(defun encode-mhvc (hue40 value chroma &optional (flag-interpolated 0))
  (encode-mhvc1000 (round (* hue40 25))
			  (round (* value 100))
			  (round (* chroma 10))
			  flag-interpolated))

(declaim (inline interpolatedp))
(defun interpolatedp (u32)
  (not (zerop (logand u32 #b10000000000000000000000000000000))))

(declaim (inline set-interpolated))
(defun set-interpolated (u32)
  (logior #b10000000000000000000000000000000 u32))

(declaim (inline set-uninterpolated))
(defun set-uninterpolated (u32)
  (logand #b01111111111111111111111111111111 u32))

(declaim (inline decode-mhvc1000))
(defun decode-mhvc1000 (u32)
  (values (logand (ash u32 -20) #b1111111111)
	  (logand (ash u32 -10) #b1111111111)
	  (logand u32 #b1111111111)))

(declaim (inline decode-mhvc))
(defun decode-mhvc (u32)
  (multiple-value-bind (h1000 v1000 c500) (decode-mhvc1000 u32)
    (values (/ h1000 25d0)
	    (/ v1000 100d0)
	    (/ c500 10d0))))

(defconstant +maxu32+ #xffffffff)

(defmacro rgb1+ (x)
  `(clamp (1+ ,x) 0 255))

(defmacro rgb1- (x)
  `(clamp (1- ,x) 0 255))

(defun make-dummy-data (&rest args)
  args
  (make-array possible-colors
	      :element-type '(unsigned-byte 32)
	      :initial-element +maxu32+))

(defun make-munsell-inversion-data (&optional (rgbspace +srgb+) (with-interpolation t))
  (declare (optimize (speed 3) (safety 1)))
  (let ((illum-c-to-foo (gen-cat-function +illum-c+ (rgbspace-illuminant rgbspace)))
	(mid (make-array possible-colors
			 :element-type '(unsigned-byte 32)
			 :initial-element +maxu32+))
	(deltae-arr (make-array possible-colors
				:element-type 'double-float
				:initial-element most-positive-double-float)))
    (dotimes (h1000 1000)
      (let ((hue (* h1000 0.04d0)))
	(format t "processing data at hue ~a / 1000~%" h1000)
	(dotimes (v1000 1001)
	  (let* ((value (* v1000 0.01d0))
		 (maxc500 (1+ (* (max-chroma-in-mrd hue value) 10))))
	    (dotimes (c500 maxc500)
	      (let ((chroma (* c500 0.1d0)))
		(multiple-value-bind (x y z)
		    (multiple-value-call illum-c-to-foo
		      (mhvc-to-xyz-illum-c hue value chroma))
		  (multiple-value-bind (qr qg qb)
		      (xyz-to-qrgb x y z :rgbspace rgbspace :clamp nil)
		    (declare (fixnum qr qg qb))
		    (if (qrgb-out-of-gamut-p qr qg qb)
			(return)
			(let ((hex (qrgb-to-rgbpack qr qg qb :rgbspace rgbspace)))
			  (let ((old-deltae (aref deltae-arr hex))
				(new-deltae (multiple-value-call #'xyz-deltaeab
					      x y z
					      (qrgb-to-xyz qr qg qb :rgbspace rgbspace)
					      :illuminant (rgbspace-illuminant rgbspace))))
			    (declare (double-float old-deltae new-deltae))
			    (when (< new-deltae old-deltae)
			      ;; rotate if the new color is nearer to the true color than the old one.
			      (setf (aref mid hex) (encode-mhvc1000 h1000 v1000 c500)
                                    (aref deltae-arr hex) new-deltae)))))))))))))
    (let ((gaps (count-gaps mid)))
      (format t "The first data has been set. The number of gaps is ~A (~A %).~%"
	      gaps (* 100 (/ gaps (float possible-colors)))))
    (when with-interpolation
      (format t "Now interpolating...~%")
      (interpolate-mid mid
		       :rgbspace rgbspace
		       :xyz-deltae #'xyz-deltaeab)
      (format t "Now filling the remaining data with an inverter...~%")
      (fill-mid-with-inverter mid
                              :rgbspace rgbspace
                              :keep-flag nil
                              :threshold 1d-4)
      (let ((num (count-interpolated mid)))
        (format t "Data has been updated. The number of inaccurate nodes are now ~A (~A %).~%"
                num (* 100 (/ num (float possible-colors)))))
      (format t "Now filling the remaining data with a partial brute force method...~%")
      (fill-mid-brute-force mid 1d0 :rgbspace rgbspace)
      (format t "Settting a flag on the nodes which give large (i.e. delta-Eab >= ~A) errors.~%" 1d0)
      (set-flag-on-mid mid 1d0 :rgbspace rgbspace))
    mid))


;; set a flag on every node, which means a larger error than STD-DELTAE.
(defun set-flag-on-mid (mid std-deltae &key (rgbspace +srgb+) (deltae #'xyz-deltaeab))
  (let ((illum-c-to-foo (gen-cat-function +illum-c+ (rgbspace-illuminant rgbspace))))
    (declare (optimize (speed 3) (safety 1))
	     ((simple-array (unsigned-byte 32)) mid)
	     ((function * double-float) deltae))
    (check-type std-deltae double-float)
    (dotimes (hex possible-colors)
      (let ((u32 (aref mid hex)))
	(declare ((unsigned-byte 32) u32))
	(let ((delta (multiple-value-call deltae
		       (rgbpack-to-xyz hex :rgbspace rgbspace)
		       (multiple-value-call illum-c-to-foo
			 (multiple-value-call #'mhvc-to-xyz-illum-c
			   (decode-mhvc u32)))
		       :illuminant (rgbspace-illuminant rgbspace))))
	  (setf (aref mid hex)
		(if (> delta std-deltae)
		    (set-interpolated u32)
		    (set-uninterpolated u32))))))))


(defun fill-mid-brute-force (mid std-deltae &key (rgbspace +srgb+))
  (let ((max-error most-positive-double-float)
	(remaining-num (count-interpolated mid)))
    (labels ((mysearch (radius) ; brute force search within a circle of RADIUS.
	       (loop for i = 1 then (1+ i) do
		    (fill-mid-brute-force-once mid std-deltae
					       :rgbspace rgbspace
					       :keep-flag nil
					       :radius radius)
		    (let ((new-error (examine-interpolation-error mid :rgbspace rgbspace :silent t))
			  (new-remaining-num (count-interpolated mid)))
		      (format t "Loop ~A: Maximum Error (Delta-Eab) = ~A, Remaining nodes=~A~%" i new-error new-remaining-num)
		      (if (and (dufy-internal:nearly<= 0.001d0 max-error new-error)
			       (<= remaining-num new-remaining-num))
			  (return)
			  (setf max-error new-error
				remaining-num new-remaining-num))))))		      
      (format t "Minor search:~%")
      (mysearch 5)
      (format t "Major search:~%")
      (mysearch 20))))

	 
(defun fill-mid-brute-force-once (mid std-deltae &key (rgbspace +srgb+) (keep-flag nil) (radius 20))
  (let ((illum-c-to-foo (gen-cat-function +illum-c+ (rgbspace-illuminant rgbspace)))
	(remaining-num 0))
    (dotimes (hex possible-colors remaining-num)
      (let ((u32 (aref mid hex)))
	(when (interpolatedp u32)
	  (let ((deltae (multiple-value-call #'xyz-deltaeab
			  (multiple-value-call illum-c-to-foo
			    (multiple-value-call #'mhvc-to-xyz-illum-c
			      (decode-mhvc u32)))
			  (rgbpack-to-xyz hex :rgbspace rgbspace)
			  :illuminant (rgbspace-illuminant rgbspace))))
	    (if (> deltae std-deltae)
	      (setf (aref mid hex)
		    (set-interpolated (search-rgbpack-to-mhvc-u32 hex u32
							     :rgbspace rgbspace
							     :radius radius))
		    remaining-num (1+ remaining-num))
	      (setf (aref mid hex)
		    (funcall (if keep-flag
				 #'identity
				 #'set-uninterpolated)
			     u32)))))))))

(defun search-rgbpack-to-mhvc-u32 (hex init-mhvc-u32 &key (rgbspace +srgb+) (radius 20))
  "Inverts HEX to HVC (u32) by partial brute force method."
  (let ((illum-c-to-foo (gen-cat-function +illum-c+ (rgbspace-illuminant rgbspace))))
    (multiple-value-bind (r255 g255 b255)
	(rgbpack-to-qrgb hex)
      (multiple-value-bind (init-h1000 init-v1000 init-c500)
	  (decode-mhvc1000 init-mhvc-u32)
	(multiple-value-bind (true-x true-y true-z)
	    (qrgb-to-xyz r255 g255 b255 :rgbspace rgbspace)
	  (let ((cand-h1000 init-h1000)
		(cand-v1000 init-v1000)
		(cand-c500 init-c500)
		(deltae (multiple-value-call #'xyz-deltaeab
			  (multiple-value-call illum-c-to-foo
			    (mhvc-to-xyz-illum-c
			     (* init-h1000 0.04d0)
			     (* init-v1000 0.01d0)
			     (* init-c500 0.1d0)))
			  true-x true-y true-z
			  :illuminant (rgbspace-illuminant rgbspace))))
	    (loop
              for h1000 from (- init-h1000 radius) to (+ init-h1000 radius)
              for hue = (* (mod h1000 1000) 0.04d0)
              do (loop
                   for v1000 from (max (- init-v1000 radius) 0) to (min (+ init-v1000 radius) 1000)
                   for value = (* v1000 0.01d0)
                   for maxc500 = (* (max-chroma-in-mrd hue value) 10)
                   do (loop
                        for c500 from (max (- init-c500 radius) 0) to (min (+ init-c500 radius) maxc500)
                        for chroma = (* c500 0.1d0)
                        do (multiple-value-bind (x y z)
			       (multiple-value-call illum-c-to-foo
				 (mhvc-to-xyz-illum-c hue value chroma))
			     (let ((new-deltae (xyz-deltaeab x y z
                                                             true-x true-y true-z
                                                             :illuminant (rgbspace-illuminant rgbspace))))
			       (when (< new-deltae deltae)
				 ;; rotate if the new color is nearer to the true color than the old one.
				 (setf cand-h1000 h1000
				       cand-v1000 v1000
				       cand-c500 c500
				       deltae new-deltae)))))))
	    (values (encode-mhvc1000 cand-h1000
				     cand-v1000
				     cand-c500
				     (if (interpolatedp init-mhvc-u32) 1 0))
		    deltae)))))))
				 
  
(defun %find-least-score (testfunc lst l-score l-node)
  (if (null lst)
      l-node
      (let ((score (funcall testfunc (car lst))))
	(if (< score l-score)
	    (%find-least-score testfunc (cdr lst) score (car lst))
	    (%find-least-score testfunc (cdr lst) l-score l-node)))))

(defun find-least-score (testfunc lst)
  "Returns a node for which the TESTFUNC gives the minimum value."
  (%find-least-score testfunc
                     lst
                     (funcall testfunc (car lst))
                     (car lst)))

;; fills MID with invert-lchab-to-mhvc and returns the number of remaining nodes.
(defun fill-mid-with-inverter (mid &key (rgbspace +srgb+) (keep-flag t) (threshold 1d-3))
  (declare (optimize (speed 3) (safety 1))
	   ((simple-array (unsigned-byte 32)) mid))
  (let ((illum-foo-to-c (gen-cat-function (rgbspace-illuminant rgbspace) +illum-c+))
	(max-iteration 500)
	(num-failure 0))
    (dotimes (hex possible-colors)
      (let ((u32 (aref mid hex)))
	(when (interpolatedp u32)
	  (multiple-value-bind (lstar cstarab hab)
	      (multiple-value-call #'xyz-to-lchab
		(multiple-value-call illum-foo-to-c 
		  (rgbpack-to-xyz hex :rgbspace rgbspace))
		:illuminant +illum-c+)
	    (multiple-value-bind (init-h disused init-c)
		(if (= u32 +maxu32+)
		    (dufy-munsell::rough-lchab-to-mhvc lstar cstarab hab)
		    (decode-mhvc u32))
	      (declare (ignore disused))
	      (multiple-value-bind (h v c)
		  (dufy-munsell::invert-mhvc-to-lchab lstar cstarab hab
                                                      init-h init-c
                                                      :max-iteration max-iteration
                                                      :if-reach-max :negative
                                                      :threshold threshold)
		(if (= h least-negative-double-float)
		    ;;(format t "failed at hex #x~X, LCHab=(~A, ~A, ~A)~%" hex lstar cstarab hab)
		    (incf num-failure)
		    (setf (aref mid hex)
			  (encode-mhvc h v c (if keep-flag 1 0))))))))))
    num-failure))

(defun interpolate-once (mid &key (rgbspace +srgb+) (xyz-deltae #'xyz-deltaeab))
  (declare (optimize (speed 3) (safety 1))
	   ((simple-array (unsigned-byte 32)) mid)
	   (function xyz-deltae))
  (let* ((source-mid (copy-seq mid))
	 (not-interpolated 0)
	 (illum-c-to-foo (gen-cat-function +illum-c+ (rgbspace-illuminant rgbspace))))
    (dotimes (hex possible-colors not-interpolated)
      (let ((u32 (aref source-mid hex)))
	(when (= u32 +maxu32+)
	  (multiple-value-bind (r g b) (rgbpack-to-qrgb hex)
	    (multiple-value-bind (x y z) (qrgb-to-xyz r g b :rgbspace rgbspace)
	      (let ((neighbors
		     (list (list r g (rgb1+ b))
			   (list r g (rgb1- b))
			   (list r (rgb1+ g) b)
			   (list r (rgb1- g) b)
			   (list (rgb1+ r) g b)
			   (list (rgb1- r) g b))))
		(let ((nearest-hex
		       (apply #'qrgb-to-rgbpack
			(find-least-score
			 #'(lambda (n-qrgb)
			     (let* ((n-hex (apply #'qrgb-to-rgbpack n-qrgb))
				    (n-u32 (aref source-mid n-hex)))
			       (if (= n-u32 +maxu32+)
				   most-positive-double-float
				   (multiple-value-call xyz-deltae
				     x y z
				     (multiple-value-call illum-c-to-foo
				       (multiple-value-call #'mhvc-to-xyz-illum-c
					 (decode-mhvc n-u32)))
				     :illuminant (rgbspace-illuminant rgbspace)))))
			 neighbors))))
		  (if (= (aref source-mid nearest-hex) +maxu32+)
		      (incf not-interpolated)
		      (setf (aref mid hex)
			    (set-interpolated (aref source-mid nearest-hex)))))))))))))



(defun interpolate-mid (munsell-inversion-data &key (rgbspace +srgb+) (xyz-deltae #'xyz-deltaeab))
  (let ((i 0))
    (loop
       (let ((remaining (interpolate-once munsell-inversion-data
					  :rgbspace rgbspace
					  :xyz-deltae xyz-deltae)))
	 (if (zerop remaining)
	     (progn
	       (format t "Loop: ~a: Perfectly interpolated.~%" (incf i))
	       (return))
	     (format t "Loop: ~a: Remaining nodes = ~A,~%" (incf i) remaining))))))


;; sets value with y-to-munsell-value in MID; Thereby chroma is properly corrected.
(define-cat-function d65-to-c +illum-d65+ +illum-c+)
(defun set-atsm-value (munsell-inversion-data)
  (dotimes (hex possible-colors)
    (multiple-value-bind (h1000 disused c500)
	(decode-mhvc1000 (aref munsell-inversion-data hex))
      (declare (ignore disused))
      (let* ((hue40 (clamp (/ h1000 25d0) 0 40))
	     (new-value (y-to-munsell-value
                         (nth-value 1 (multiple-value-call #'d65-to-c
                                        (rgbpack-to-xyz hex)))))
	     (chroma (* c500 0.1d0))
	     (v1000-new (round (* new-value 100)))
	     (c500-new (round (* (min (max-chroma-in-mrd hue40 new-value) chroma) 10))))
	(setf (aref munsell-inversion-data hex) (encode-mhvc1000 h1000 v1000-new c500-new))))))


(defun absolute-p (path)
  (eql (car (pathname-directory (parse-namestring path)))
       :absolute))

(defun save-munsell-inversion-data (munsell-inversion-data &optional (filename-str "srgbd65-to-munsell-be.dat"))
  "saves/loads Munsell inversion data to/from a binary file in big endian format."
  (let ((path (if (absolute-p filename-str)
		  filename-str
		  (merge-pathnames (asdf:system-source-directory :dufy) filename-str))))
    (with-open-file (out path
			 :direction :output
			 :element-type '(unsigned-byte 8)
			 :if-exists :supersede)
      (fast-io:with-fast-output  (buf out)
	(dotimes (x possible-colors)
	  (fast-io:writeu32-be (aref munsell-inversion-data x) buf)))
      (format t "Munsell inversion data is saved in ~A.~%" path))))

(defun load-munsell-inversion-data (&optional (filename-str "srgbd65-to-munsell-be.dat"))
  (let ((path (if (absolute-p filename-str)
		  filename-str
		  (merge-pathnames (asdf:system-source-directory :dufy) filename-str))))
    (with-open-file (in path
			:direction :input
			:element-type '(unsigned-byte 8))
      (let ((munsell-inversion-data (make-array possible-colors :element-type '(unsigned-byte 32) :initial-element +maxu32+)))
	(fast-io:with-fast-input (buf nil in)
	  (dotimes (x possible-colors munsell-inversion-data)
	    (setf (aref munsell-inversion-data x) (fast-io:readu32-be buf))))))))
	

(defun check-data-from-srgb (munsell-inversion-data r g b)
  (let ((u32 (aref munsell-inversion-data (qrgb-to-rgbpack r g b))))
    (if (= u32 +maxu32+)
	nil
	(multiple-value-call #'mhvc-to-qrgb (decode-mhvc u32) :clamp nil))))

(defun check-all-data (munsell-inversion-data)
  (dotimes (x possible-colors)
    (let* ((srgb (multiple-value-list (rgbpack-to-qrgb x)))
	   (srgb2 (multiple-value-list (apply #'check-data-from-srgb (append (list munsell-inversion-data) srgb)))))
      (unless (null srgb2)
	(when (not (equal srgb srgb2))
	  (format t "inacurrate value at position: ~a" x))))))
	  

;; QRGB to munsell HVC
(defun qrgb-to-mhvc (qr qg qb munsell-inversion-data)
  (decode-mhvc (aref munsell-inversion-data (qrgb-to-rgbpack qr qg qb))))

(defun qrgb-to-munsell (qr qg qb munsell-inversion-data)
  (multiple-value-call #'mhvc-to-munsell
    (qrgb-to-mhvc qr qg qb munsell-inversion-data)))

(defun rgbpack-to-mhvc (hex munsell-inversion-data)
  (decode-mhvc (aref munsell-inversion-data hex)))

;; one-in-all function
;; (defun generate-all (&key (filename "srgbd65-to-munsell-be.dat") (with-interpolate t))
;;   (time
;;    (progn
;;      (format t "generating Munsell inversion data...~%")
;;      (make-munsell-inversion-data)
;;      ;; (format t "checking the reliability of the data...~%")
;;      ;; (check-all-data)
;;      (when with-interpolate
;;        (format t "interpolating the Munsell inversion data...~%")
;;        (interpolate-mid))
;;      (format t "save data to ~a.~%" filename)
;;      (save-dat-file filename))))

(defun build-mid (&optional (filename "srgbd65-to-munsell-be.dat") (with-interpolation t))
  (format t "generating Munsell inversion data...~%")
  (save-munsell-inversion-data
   (make-munsell-inversion-data with-interpolation)
   filename))

(defun count-gaps (munsell-inversion-data)
  (let ((gaps 0))
    (dotimes (hex possible-colors)
      (when (= +maxu32+ (aref munsell-inversion-data hex))
	  (incf gaps)))
    gaps))


(defun count-interpolated (munsell-inversion-data)
  (let ((num 0))
    (dotimes (hex possible-colors num)
      (when (interpolatedp (aref munsell-inversion-data hex))
	  (incf num)))))

  
(defun gap-rate-b (munsell-inversion-data)
  (let ((gaps-sum 0))
    (dotimes (b 256)
     (let ((gaps 0))
       (dotimes (r 256)
	 (dotimes (g 256)
	   (if (= +maxu32+ (aref munsell-inversion-data (qrgb-to-rgbpack r g b)))
	       (incf gaps))))
       (format t "b = ~a, gap rate = ~a~%" b (/ gaps 65536.0))
       (setf gaps-sum (+ gaps-sum gaps))))
    (format t "total gap rate = ~a~%" (/ gaps-sum (float possible-colors)))))


(defun gap-rate-by-flag (munsell-inversion-data)
  (let ((gaps-sum 0))
    (dotimes (b 256)
     (let ((gaps 0))
       (dotimes (r 256)
	 (dotimes (g 256)
	   (if (interpolatedp (aref munsell-inversion-data (qrgb-to-rgbpack r g b)))
	       (incf gaps))))
       (format t "b = ~a, gap rate = ~a~%" b (/ gaps 65536.0))
       (setf gaps-sum (+ gaps-sum gaps))))
    (format t "total gap rate = ~a~% (~A nodes)" (/ gaps-sum (float possible-colors)) gaps-sum)))

(defun gap-rate-by-brightness (munsell-inversion-data)
  (let ((gaps-sum 0))
    (loop for brightness-sum from 0 to 765 do
	 (let ((gaps 0)
	       (number-of-colors 0)
	       (max-r (min 255 brightness-sum)))
	   (loop for r from 0 to max-r do
		(let ((min-g (max 0 (- brightness-sum 255 r)))
		      (max-g (min 255 (- brightness-sum r))))
		  (loop for g from min-g to max-g do
		       (let ((min-b (max 0 (- brightness-sum r g)))
			     (max-b (min 255 (- brightness-sum r g))))
			 (loop for b from min-b to max-b do
			      (incf number-of-colors)
			      (when (= +maxu32+ (aref munsell-inversion-data (qrgb-to-rgbpack r g b)))
				(incf gaps)
				(incf gaps-sum)))))))
	   (format t "brightness = ~a, gap rate = ~a (= ~a / ~a).~%"
		   brightness-sum
		   (/ (float gaps) number-of-colors) 
		   gaps
		   number-of-colors)))
    (format t "total gap rate = ~a~%" (/ gaps-sum (float possible-colors)))))
    

;; examines the total error of interpolated data in MID and
;; returns maximum delta-E.
(defun examine-interpolation-error (munsell-inversion-data &key (rgbspace +srgb+) (deltae #'xyz-deltaeab) (silent nil) (all-data nil))
  (declare (optimize (speed 3) (safety 1))
           (type function deltae)
           (type (simple-array (unsigned-byte 32) (*)) munsell-inversion-data))
  (let ((illum-c-to-foo (gen-cat-function +illum-c+ (rgbspace-illuminant rgbspace)))
	(maximum 0d0)
	(worst-hex nil)
	(sum 0d0)
	(nodes 0))
    (pdotimes (hex possible-colors)
      (let ((u32 (aref munsell-inversion-data hex)))
        (when (or all-data
                  (interpolatedp u32))
          (let ((delta (multiple-value-call deltae
                         (rgbpack-to-xyz hex :rgbspace rgbspace)
                         (multiple-value-call illum-c-to-foo
                           (multiple-value-call #'mhvc-to-xyz-illum-c
                             (decode-mhvc u32)))
                         :illuminant (rgbspace-illuminant rgbspace))))
            (declare (double-float delta maximum))
            (setf sum (+ sum delta))
            (when (> delta maximum)
              (setf maximum delta
                    worst-hex hex))
            (incf nodes)))))
    (let ((mean (/ sum (max nodes 1))))
      (unless silent
	(format t "Number of Examined Nodes = ~A (~,5F%)~%" nodes (* 100d0 (/ nodes possible-colors)))
	(format t "Mean Color Difference: ~a~%" mean)
	(format t "Maximum Color Difference: ~a at hex #x~x~%" maximum worst-hex))
      (values mean maximum))))

;; (dufy-tools:examine-interpolation-error mid :rgbspace dufy:+srgb+ :deltae #'dufy:qrgb-deltaeab)
;; Number of Interpolated Nodes = 3716978 (22.155%)
;; Mean Color Difference: 0.32306172649351494d0
;; Maximum Color Difference: 10.381509801482807d0 at hex #x45F4
;; (dufy-tools::count-bad-nodes mid 2d0)
;; => 19978

;; (dufy-tools::fill-mid-with-inverter mid :threshold 0.001d0)
;; Number of failure: 120734
;; (dufy-tools:examine-interpolation-error mid :rgbspace dufy:+srgb+)
;; Number of Interpolated Nodes = 3716978 (22.155%)
;; Mean Color Difference: 0.2874144244305755d0
;; Maximum Color Difference: 5.651441223696464d0 at hex #x412600
;; (dufy-tools::count-bad-nodes mid 2d0)
;; => 249

;; (dufy-tools::fill-mid-with-inverter mid :threshold 0.01d0)
;; Number of failure: 120734
;; (dufy-tools:examine-interpolation-error mid :rgbspace dufy:+srgb+)
;; Number of Interpolated Nodes = 3716978 (22.155%)
;; Mean Color Difference: 0.29621689179528365d0
;; Maximum Color Difference: 5.651441223696464d0 at hex #x412600


;; count the nodes in MID which are too far from true colors.
(defun count-bad-nodes (munsell-inversion-data std-deltae &key (rgbspace +srgb+) (deltae #'qrgb-deltaeab) (all-data nil))
  (let ((illum-c-to-foo (gen-cat-function +illum-c+ (rgbspace-illuminant rgbspace)))
	(num-nodes 0))
    (loop for hex from 0 below possible-colors do
      (let ((u32 (aref munsell-inversion-data hex)))
	(when (or all-data
		  (interpolatedp u32))
	  (multiple-value-bind  (r1 g1 b1) (rgbpack-to-qrgb hex)
	    (multiple-value-bind (r2 g2 b2)
		(multiple-value-call #'xyz-to-qrgb
		  (multiple-value-call illum-c-to-foo
		    (multiple-value-call #'mhvc-to-xyz-illum-c
		      (decode-mhvc u32)))
		  :rgbspace rgbspace
                  :clamp nil)
	      (let ((delta (funcall deltae r1 g1 b1 r2 g2 b2 :rgbspace rgbspace)))
		(when (> delta std-deltae)
		  (incf num-nodes))))))))
    num-nodes))


(defun check-error-of-hex (hex mid &optional (deltae #'qrgb-deltaeab))
  (let* ((rgb1 (multiple-value-list (rgbpack-to-qrgb hex)))
	 (rgb2 (multiple-value-call #'mhvc-to-qrgb
		 (apply (rcurry #'qrgb-to-mhvc mid)
			rgb1)
                 :clamp nil)))
    (format t "Munsell HVC: ~A~%" (decode-mhvc (aref mid hex)))
    (format t "in MID:~A~%" rgb1)
    (format t "true: ~A~%" rgb2) 
    (format t "Delta E = ~A~%" (apply deltae (append rgb1 rgb2)))))

(defun examine-luminance-error (munsell-inversion-data &key (start 0) (end possible-colors) (all-data nil))
  (let ((maximum 0)
	(worst-hex nil)
	(sum 0)
	(nodes 0))
    (loop for hex from start below end do
      (let ((u32 (aref munsell-inversion-data hex)))
	(if (or all-data
		(interpolatedp u32))
	    (let ((v1 (y-to-munsell-value (nth-value 1 (rgbpack-to-xyz hex))))
		  (v2 (nth-value 1 (decode-mhvc u32))))
	      (let ((delta (abs (- v1 v2))))
		(setf sum (+ sum delta))
		(when (> delta maximum)
		  (setf maximum delta)
		  (setf worst-hex hex))
		(incf nodes))))))
    (format t "Number of Examined Nodes = ~A (~,3F%)~%" nodes (* 100d0 (/ nodes (- end start))))
    (format t "Mean Error of Munsell Values: ~a~%" (/ sum nodes))
    (format t "Maximum Error of Munsell Values: ~a at hex #x~X~%" maximum worst-hex)))

;; Number of Interpolated Nodes = 3716977 (22.155%)
;; Mean Error of Munsell Values: 0.029526621135807438d0
;; Maximum Error of Munsell Values: 0.36599623828091055d0 at hex 585474

(defun compare-two-mids (mid1 mid2)
  (let ((maximum-delta 0d0)
	(sum 0d0)
	(most-inferior-idx 0))
  (dotimes (idx possible-colors)
    (let* ((node1 (multiple-value-list (multiple-value-call #'mhvc-to-xyz
					 (decode-mhvc (aref mid1 idx)))))
	   (node2 (multiple-value-list (multiple-value-call #'mhvc-to-xyz
					 (decode-mhvc (aref mid2 idx)))))
	   (delta (apply #'xyz-deltaeab
			 (append node1 node2))))
      (setf sum (+ sum delta))
      (when (> delta maximum-delta)
	(setf maximum-delta delta)
	(setf most-inferior-idx idx))))
  (format t "Maximum Delta E = ~A at index ~X~%" maximum-delta most-inferior-idx)
  (format t "Mean Delta E = ~A~%" (float (/ sum possible-colors) 1d0))))


  
(defun delete-interpolated-nodes (mid)
  (dotimes (hex possible-colors)
    (let ((node (aref mid hex)))
      (when (interpolatedp node)
	(setf (aref mid hex) +maxu32+)))))

;; get the maximun radius of the spheres of missing values in the non-interpolated munsell inversion data.
;; (defun get-radius-of-blank-sphere (mid depth r g b)
;;   (if (not (= +maxu32+ (aref mid (dufy:qrgb-to-rgbpack r g b))))
;;       depth
;;       (max (get-radius-of-blank-sphere mid (1+ depth) r g (rgb1+ b))
;; 	   (get-radius-of-blank-sphere mid (1+ depth) r g (rgb1- b))
;; 	   (get-radius-of-blank-sphere mid (1+ depth) r (rgb1+ g) b)
;; 	   (get-radius-of-blank-sphere mid (1+ depth) r (rgb1- g) b)
;; 	   (get-radius-of-blank-sphere mid (1+ depth) (rgb1+ r) g b)
;; 	   (get-radius-of-blank-sphere mid (1+ depth) (rgb1- r) g b))))

;; (defun maximum-radius-of-blank-sphere (mid)
;;   (let ((maximum 0))
;;     (dotimes (hex possible-colors maximum)
;;       (when (= (mod hex 10000) 0)
;; 	(format t "~a / ~a hues were processed." hex possible-colors))
;;       (let ((rad (apply #'get-radius-of-blank-sphere mid 0 (dufy:rgbpack-to-qrgb hex))))
;; 	(if (> rad maximum)
;; 	    (setf maximum rad))))))



;; (defun find-value-in-mrd (value)
;;   (let ((xyy-lst nil))
;;     (dolist (line munsell-renotation-data xyy-lst)
;;       (when (= (second line) value)
;; 	(push (cdddr line) xyy-lst)))))


;; (defun find-value-in-general (value)
;;   (let ((xyy-lst nil))
;;     (dotimes (hue40 40 xyy-lst)
;;       (let ((max-c (dufy:max-chroma-in-mrd hue40 value)))
;; 	(dotimes (chroma max-c)
;; 	  (push (dufy:mhvc-to-xyy hue40 value chroma)
;; 		xyy-lst))))))

;; (defun test-blue (lb)
;;   (apply #'xyz-to-lchab (lrgb-to-xyz 0 0 lb)))

