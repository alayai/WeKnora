package container

import (
	"errors"
	"testing"
)

func TestIsTransientNetworkError(t *testing.T) {
	cases := []struct {
		err  error
		want bool
	}{
		{err: errors.New("read: connection reset by peer"), want: true},
		{err: errors.New("dial tcp 127.0.0.1:16379: connect: connection refused"), want: true},
		{err: errors.New("NOAUTH Authentication required"), want: false},
		{err: errors.New("WRONGPASS invalid username-password pair"), want: false},
		{err: nil, want: false},
	}
	for _, tc := range cases {
		if got := isTransientNetworkError(tc.err); got != tc.want {
			t.Errorf("isTransientNetworkError(%v) = %v, want %v", tc.err, got, tc.want)
		}
	}
}
